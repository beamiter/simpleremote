vim9script

# Local UI / remote filesystem bridge.  The remote side is intentionally not
# Vim-specific: it is a small shell agent speaking a line protocol.
var s_remote: dict<any> = {}
var s_next_id = 0
var s_generation = 0
var s_base64_decode_flag = ''
var s_connect_spec: dict<any> = {}
var s_last_spec: dict<any> = {}
var s_tree: dict<any> = {}
var s_previous_cwd = ''
var s_workspace_switch_timer = 0
var s_tree_clipboard: dict<any> = {}
var s_tree_bookmarks: dict<any> = {}
var s_tree_bookmarks_loaded = false
var s_runtime_capabilities: dict<any> = {}

const PROTOCOL = 'simpleremote/2'
# Captured at script level: <sfile> cannot be expanded inside a :def.
const SCRIPT_ROOT = fnamemodify(expand('<sfile>:p'), ':h:h')
# The JSON bridge revision this Vim side speaks; the runtime advertises its own
# in `simpleremote-daemon capabilities` and the two must agree.
const BRIDGE_PROTOCOL = 1

g:vimrc_remote_status = 'disconnected'
g:simpleremote_status = 'disconnected'

def SetStatus(status: string)
  g:vimrc_remote_status = status
  g:simpleremote_status = status
enddef

def B64(value: string): string
  # base64 without GNU's -w flag works on both GNU and BSD implementations.
  return system('base64', value)->substitute('\n', '', 'g')
enddef

def Base64DecodeFlag(): string
  if !empty(s_base64_decode_flag)
    return s_base64_decode_flag
  endif
  system('base64 -d', '')
  if v:shell_error == 0
    s_base64_decode_flag = '-d'
    return s_base64_decode_flag
  endif
  system('base64 -D', '')
  s_base64_decode_flag = v:shell_error == 0 ? '-D' : '-d'
  return s_base64_decode_flag
enddef

def UnB64(value: string): string
  return system('base64 ' .. Base64DecodeFlag(), value)
enddef

# UnB64() cannot carry a file body: system() replaces every NUL in its output
# with SOH, so a byte that a binary file legitimately contains would reach the
# buffer as a different one and be written back that way.  Vim's own binary
# representation — a NUL inside a line, lines separated by NL, which is what
# readfile(..., 'b') produces and writefile(..., 'b') consumes — has no such
# hole, so file bodies travel through a temporary file instead of a pipe.
# Everything else (listings, command output, error messages) keeps the cheap
# path: none of it can contain a NUL that means anything.
def DecodeBase64ToLines(encoded: string): list<string>
  var encoded_file = tempname()
  var raw_file = tempname()
  var lines: list<string> = []
  try
    writefile([encoded], encoded_file)
    system(printf('base64 %s < %s > %s', Base64DecodeFlag(),
      shellescape(encoded_file), shellescape(raw_file)))
    if v:shell_error == 0 && filereadable(raw_file)
      lines = readfile(raw_file, 'b')
    endif
  catch
    lines = []
  finally
    delete(encoded_file)
    delete(raw_file)
  endtry
  return lines
enddef

# The mirror image: buffer lines to base64, with the final newline expressed
# the way readfile()/writefile() express it — a trailing empty item.
def EncodeLinesToBase64(lines: list<string>, final_eol: bool): string
  var raw_file = tempname()
  var encoded = ''
  try
    writefile(final_eol ? lines + [''] : lines, raw_file, 'b')
    encoded = system(printf('base64 < %s', shellescape(raw_file)))
      ->substitute('\n', '', 'g')
  catch
    encoded = ''
  finally
    delete(raw_file)
  endtry
  return encoded
enddef

def Error(message: string)
  echohl ErrorMsg
  echomsg message
  echohl None
enddef

def Emit(event: string, payload: dict<any> = {})
  g:simpleremote_event = extend(copy(payload), {
    event: event,
    status: get(g:, 'simpleremote_status', 'disconnected'),
    time: localtime(),
  })
  execute 'silent! doautocmd <nomodeline> User ' .. event
enddef

def IsCurrent(generation: number): bool
  return !empty(s_remote) && get(s_remote, 'generation', -1) == generation
enddef

def IsReady(): bool
  return !empty(s_remote) && get(s_remote, 'state', '') ==# 'ready'
enddef

def ClearGlobals()
  SetStatus('disconnected')
  unlet! g:vimrc_remote_workspace
  unlet! g:vimrc_remote_simplecc_config
  unlet! g:simpleremote_workspace
enddef

def StopRequestTimer(entry: dict<any>)
  var timer = get(entry, 'timer', 0)
  if timer > 0
    timer_stop(timer)
  endif
enddef

# A failure has to reach the callback in the shape that callback was declared
# for.  A wants_lines request types its payload list<string>, so handing it a
# bare message aborts with E1013 and hides the real failure; OnLine() already
# wraps an error reply the same way.
def FailRequest(Callback: func, wants_lines: bool, message: string)
  if wants_lines
    call(Callback, [false, [message]])
  else
    call(Callback, [false, message])
  endif
enddef

def RequestTimedOut(generation: number, key: string)
  if !IsCurrent(generation) || !has_key(s_remote.pending, key)
    return
  endif
  var entry = remove(s_remote.pending, key)
  FailRequest(entry.callback, get(entry, 'wants_lines', false),
    'request timed out: ' .. entry.operation)
enddef

# The agent's line protocol carries one base64 payload per request.  With the
# JSON bridge (simpleremote-daemon agent --protocol json) the runtime performs
# every encoding step in-process and Vim exchanges plain JSON objects; without
# it, Vim spawns `base64` itself exactly as it always has.
def LegacyPayload(op: string, args: dict<any>): string
  if op ==# 'write'
    # content_b64 is already the agent's inner layer, byte for byte.
    return get(args, 'path', '') .. "\t" .. (has_key(args, 'content_b64')
      ? args.content_b64 : B64(get(args, 'content', '')))
  endif
  if op ==# 'exec' || op ==# 'grep'
    return get(args, 'command', '')
  endif
  return get(args, 'path', '')
enddef

def WireLine(id: number, op: string, args: dict<any>): string
  if get(s_remote, 'protocol', 'legacy') ==# 'json'
    var request = extend({id: id, op: op}, args, 'keep')
    if op ==# 'write' && !has_key(request, 'content_b64')
      # json_encode() replaces invalid UTF-8 with U+FFFD; base64 keeps every
      # byte of a latin-1 or mixed-encoding buffer intact on the way out.
      request.content_b64 = B64(get(args, 'content', ''))
    endif
    if op ==# 'write' && has_key(request, 'content')
      remove(request, 'content')
    endif
    return json_encode(request) .. "\n"
  endif
  return id .. "\t" .. op .. "\t" .. B64(LegacyPayload(op, args)) .. "\n"
enddef

def RequestTimeout(): number
  return max([0, get(g:, 'simpleremote_request_timeout',
    get(g:, 'vimrc_remote_request_timeout', 15000))])
enddef

# `wants_lines` asks for the reply as buffer lines — Vim's binary
# representation, byte for byte — instead of a string that cannot hold a NUL.
# `timeout_ms` overrides g:simpleremote_request_timeout for one request, which
# is how a read sized in advance buys the time its size needs.
def Send(op: string, args: dict<any>, Callback: func,
    wants_lines: bool = false, timeout_ms: number = -1): number
  if empty(s_remote) || get(s_remote, 'channel', v:null) == v:null
    Error('[VimrcRemote] not connected')
    FailRequest(Callback, wants_lines, 'not connected')
    return -1
  endif
  if ch_status(s_remote.channel) !=# 'open'
    Error('[VimrcRemote] transport is not writable')
    FailRequest(Callback, wants_lines, 'transport is not writable')
    return -1
  endif

  s_next_id += 1
  var id = s_next_id
  var key = string(id)
  var generation = s_remote.generation
  var timeout = timeout_ms >= 0 ? timeout_ms : RequestTimeout()
  var timer = timeout > 0
        ? timer_start(timeout, (_) => RequestTimedOut(generation, key))
        : 0
  s_remote.pending[key] = {
    callback: Callback,
    operation: op,
    timer: timer,
    wants_lines: wants_lines,
  }
  try
    ch_sendraw(s_remote.channel, WireLine(id, op, args))
  catch
    var failed_here = false
    if IsCurrent(generation) && has_key(s_remote.pending, key)
      var entry = remove(s_remote.pending, key)
      StopRequestTimer(entry)
      failed_here = true
    endif
    # OnExit may have run while ch_sendraw() was failing.  In that case it
    # already completed every pending callback, so never invoke this one twice.
    if failed_here
      Error('[VimrcRemote] transport is not writable')
      FailRequest(Callback, wants_lines, 'transport is not writable')
    endif
    return -1
  endtry
  return id
enddef

# New agents encode the filename field inside directory-listing rows.  Keep
# the protocol revision stable and negotiate by operation name: an old agent
# answers "unknown operation", at which point the next legacy operation is
# tried.  Conversely, the new agent still serves those legacy operations.
def SendDirectoryListingAttempt(path: string, attempts: list<dict<any>>,
    index: number, Callback: func): number
  var attempt = attempts[index]
  var generation = get(s_remote, 'generation', -1)
  return Send(attempt.operation, {path: path}, (ok, body) => {
    var unknown = !ok && body =~# '^unknown operation:'
    if IsCurrent(generation)
      # Operation support belongs to the agent process, hence to this
      # connection generation.  Remember both positive and negative probes so
      # an old agent pays the compatibility fallback only once rather than
      # once for every directory expanded in the tree.
      if !has_key(s_remote, 'listing_operations')
        s_remote.listing_operations = {}
      endif
      s_remote.listing_operations[attempt.operation] = unknown ? 0 : 1
    endif
    if unknown && index + 1 < len(attempts)
      SendDirectoryListingAttempt(path, attempts, index + 1, Callback)
      return
    endif
    call(Callback, [ok, body, attempt])
  })
enddef

def SendDirectoryListing(path: string, metadata: bool, Callback: func): number
  var attempts = metadata
    ? [
        {operation: 'list-meta-encoded', encoded: true, metadata: true},
        {operation: 'list-meta', encoded: false, metadata: true},
        {operation: 'list-encoded', encoded: true, metadata: false},
        {operation: 'list', encoded: false, metadata: false},
      ]
    : [
        {operation: 'list-encoded', encoded: true, metadata: false},
        {operation: 'list', encoded: false, metadata: false},
      ]
  var support = get(s_remote, 'listing_operations', {})
  filter(attempts,
    (_, attempt) => get(support, attempt.operation, -1) != 0)
  # `list` is part of every v2 agent.  Keep a deterministic request even if a
  # broken peer previously claimed otherwise, so callers receive its concrete
  # error instead of an indexing exception here.
  if empty(attempts)
    attempts = [{operation: 'list', encoded: false, metadata: false}]
  endif
  return SendDirectoryListingAttempt(path, attempts, 0, Callback)
enddef

def ListingName(field: string, encoded: bool): string
  return encoded ? UnB64(field) : field
enddef

# Every reply reaches its callback fully decoded: file bodies for read and
# read-config, listings, command output, or an error message.
def DecodeLine(line: string): dict<any>
  if get(s_remote, 'protocol', 'legacy') ==# 'json'
    var message: any
    try
      message = json_decode(line)
    catch
      return {}
    endtry
    if type(message) != v:t_dict || !has_key(message, 'id')
      return {}
    endif
    var binary = has_key(message, 'data_b64')
    var data = binary ? get(message, 'data_b64', '') : get(message, 'data', '')
    return {
      key: string(get(message, 'id', '')),
      ok: !!get(message, 'ok', false),
      # Left encoded when it is binary: only the caller knows whether it wants
      # bytes (a buffer) or text (an API consumer).
      data: type(data) == v:t_string ? data : string(data),
      binary: binary,
    }
  endif
  var parts = split(line, "\t", 1)
  if len(parts) != 3
    return {}
  endif
  # The outer layer is always base64 text, so decoding it through a pipe is
  # safe; whether the result is itself encoded depends on the operation.
  return {key: parts[0], ok: parts[1] ==# 'ok', data: UnB64(parts[2]),
    binary: false}
enddef

def OnLine(generation: number, _channel: any, line: string)
  if !IsCurrent(generation)
    return
  endif
  var reply = DecodeLine(line)
  if empty(reply) || !has_key(s_remote.pending, reply.key)
    return
  endif
  var entry = remove(s_remote.pending, reply.key)
  StopRequestTimer(entry)
  var legacy = get(s_remote, 'protocol', 'legacy') !=# 'json'
  var reads_a_file = entry.operation ==# 'read' || entry.operation ==# 'read-config'
  # The agent base64-encodes file bodies before the protocol layer encodes the
  # whole reply.  What is still encoded at this point differs by transport:
  # legacy has the agent's inner layer, the bridge sends data_b64 only for
  # payloads a JSON string cannot carry.
  var encoded = reply.ok && (reply.binary || (legacy && reads_a_file))
  if get(entry, 'wants_lines', false)
    var lines = !reply.ok ? [reply.data]
      : encoded ? DecodeBase64ToLines(reply.data)
      : RemoteLines(reply.data, false)
    call(entry.callback, [reply.ok, lines])
    return
  endif
  var data = encoded ? UnB64(reply.data) : reply.data
  call(entry.callback, [reply.ok, data])
enddef

def OnError(generation: number, _channel: any, line: string)
  if !IsCurrent(generation) || empty(line)
    return
  endif
  add(s_remote.stderr, line)
  if len(s_remote.stderr) > 20
    remove(s_remote.stderr, 0)
  endif
enddef

def FailPending(remote: dict<any>, message: string)
  for entry in values(get(remote, 'pending', {}))
    StopRequestTimer(entry)
    FailRequest(entry.callback, get(entry, 'wants_lines', false), message)
  endfor
enddef

def OnExit(generation: number, _job: any, status: number)
  if !IsCurrent(generation)
    return
  endif
  var remote = s_remote
  s_remote = {}
  DeactivateWorkspace(remote)
  ClearGlobals()
  FailPending(remote, printf('connection closed (%d)', status))
  var detail = empty(remote.stderr) ? '' : ': ' .. remote.stderr[-1]
  echomsg printf('[VimrcRemote] connection closed (%d)%s', status, detail)
  Emit('SimpleRemoteDisconnected', {reason: 'disconnect', cause: 'transport-exit', code: status})
enddef

def AgentPath(): string
  return get(g:, 'simpleremote_agent',
    get(g:, 'vimrc_remote_agent', '~/.cache/vimrc/simpleremote-agent.sh'))
enddef

def DaemonPath(): string
  if !get(g:, 'simpleremote_use_daemon', 1)
    return ''
  endif
  var path = fnamemodify(expand(get(g:, 'simpleremote_daemon_path', '')), ':p')
  return executable(path) ? path : ''
enddef

# What the installed runtime can do, asked once per binary build.  A plugin
# update that outruns `install.sh` therefore degrades to the runtime's older
# behaviour instead of failing to connect, and a rebuild is noticed by mtime.
def RuntimeCapabilities(daemon: string = DaemonPath()): dict<any>
  if empty(daemon)
    return {}
  endif
  var key = daemon .. "\t" .. getftime(daemon)
  if has_key(s_runtime_capabilities, key)
    return s_runtime_capabilities[key]
  endif
  var capabilities: dict<any> = {}
  var output = system(shellescape(daemon) .. ' capabilities')
  if v:shell_error == 0
    try
      var decoded = json_decode(output)
      if type(decoded) == v:t_dict
        capabilities = decoded
      endif
    catch
    endtry
  endif
  s_runtime_capabilities = {[key]: capabilities}
  return capabilities
enddef

# 'json' asks for the bridge, an action name asks whether the runtime has that
# subcommand, and any other name is a boolean flag of the capabilities object.
def RuntimeSupports(feature: string): bool
  var capabilities = RuntimeCapabilities()
  if feature ==# 'json'
    return index(get(capabilities, 'agent_protocols', []), 'json') >= 0
      && get(capabilities, 'bridge_protocol', 0) == BRIDGE_PROTOCOL
  endif
  if index(get(capabilities, 'actions', []), feature) >= 0
    return true
  endif
  return !!get(capabilities, feature, false)
enddef

def RuntimeVersion(): string
  return get(RuntimeCapabilities(), 'version', '')
enddef

def AgentSourcePath(): string
  return get(g:, 'simpleremote_agent_source',
    SCRIPT_ROOT .. '/bin/simpleremote-agent.sh')
enddef

const AGENT_HEREDOC = 'SIMPLEREMOTE_AGENT_EOF'

# The remote-side path expression: `~/x` becomes "$HOME"/'x' so the remote
# shell expands the home directory, anything else is quoted literally.
def AgentPathExpression(agent: string): string
  return strpart(agent, 0, 2) ==# '~/'
    ? '"$HOME"/' .. ShellLiteral(strpart(agent, 2))
    : ShellLiteral(agent)
enddef

# The self-installing agent launcher used when the Rust runtime is absent; the
# runtime builds the identical shape itself from --agent-source.  The bundled
# agent travels inside a quoted heredoc, is compared with cmp against the
# installed copy and replaces it atomically only when they differ, so a first
# connection or a plugin update never needs :SimpleRemoteInstallAgent.  An
# unwritable destination falls back to whatever agent is already installed.
def AgentBootstrapScript(agent: string): string
  var source = AgentSourcePath()
  var destination = AgentPathExpression(agent)
  if !filereadable(source)
    return 'exec ' .. destination
  endif
  # Text mode: a final newline must not become an extra empty line, or the
  # shipped copy would differ from the source by one byte on every connect.
  var lines = readfile(source)
  if index(lines, AGENT_HEREDOC) >= 0
    return 'exec ' .. destination
  endif
  return 'dst=' .. destination
    .. '; dir=$(dirname -- "$dst"); um=$(umask); umask 077; '
    .. 'mkdir -p -- "$dir" 2>/dev/null; '
    .. 'tmp=$(mktemp "$dir/.simpleremote-agent.XXXXXX" 2>/dev/null) || tmp=; '
    .. 'if [ -n "$tmp" ]; then '
    .. 'cat >"$tmp" <<' .. "'" .. AGENT_HEREDOC .. "'\n"
    .. join(lines, "\n") .. "\n" .. AGENT_HEREDOC .. "\n"
    .. 'if [ -x "$dst" ] && cmp -s -- "$tmp" "$dst"; then rm -f -- "$tmp"; '
    .. 'elif chmod 700 -- "$tmp" && mv -f -- "$tmp" "$dst"; then :; '
    .. 'else rm -f -- "$tmp"; fi; fi; '
    # The agent, and every command it runs, must see the login umask — not
    # the private one this installer needed.
    .. 'umask "$um"; '
    .. 'if [ -x "$dst" ]; then exec "$dst"; fi; '
    .. 'printf ' .. "'simpleremote: cannot install agent at %s\\n'"
    .. ' "$dst" >&2; exit 126'
enddef

def OnRuntimeProbeLine(generation: number, _channel: any, line: string)
  if IsCurrent(generation) && !empty(line)
    add(s_remote.runtime_probe_lines, line)
  endif
enddef

def OnRuntimeProbeError(generation: number, _channel: any, line: string)
  if IsCurrent(generation) && !empty(line)
    s_remote.runtime_probe_error = line
  endif
enddef

# Vim may run exit_cb before the last of a job's output has been read, so the
# probe is only assembled once the job has exited AND its channel has closed.
# Finalising on exit alone loses the whole reply on a fast machine — which is
# what a green local run and a red CI run disagreed about.
def FinalizeRuntimeProbe(generation: number)
  if !IsCurrent(generation)
    return
  endif
  if !get(s_remote, 'probe_exited', false) || !get(s_remote, 'probe_closed', false)
    return
  endif
  var probe: dict<any> = {status: get(s_remote, 'probe_status', -1)}
  for line in get(s_remote, 'runtime_probe_lines', [])
    var separator = stridx(line, '=')
    if separator > 0
      probe[strpart(line, 0, separator)] = strpart(line, separator + 1)
    endif
  endfor
  if !empty(get(s_remote, 'runtime_probe_error', ''))
    probe.error = s_remote.runtime_probe_error
  endif
  s_remote.runtime_probe = probe
  if !IsReady()
    # Still handshaking: the Connected snapshot will carry the probe, and
    # publishing g:simpleremote_workspace early would let siblings act on a
    # workspace that has not been announced yet.
    return
  endif
  g:simpleremote_workspace = WorkspaceSnapshot()
  Emit('SimpleRemoteRuntimeReady', copy(g:simpleremote_workspace))
enddef

def OnRuntimeProbeExit(generation: number, _job: any, status: number)
  if !IsCurrent(generation)
    return
  endif
  s_remote.probe_exited = true
  s_remote.probe_status = status
  FinalizeRuntimeProbe(generation)
enddef

def OnRuntimeProbeClosed(generation: number, _channel: any)
  if !IsCurrent(generation)
    return
  endif
  s_remote.probe_closed = true
  FinalizeRuntimeProbe(generation)
enddef

def StartRuntimeProbe(generation: number)
  var daemon = DaemonPath()
  if empty(daemon) || !IsCurrent(generation)
    return
  endif
  s_remote.runtime_probe_lines = []
  s_remote.runtime_probe_error = ''
  s_remote.runtime_probe = {status: -1}
  s_remote.probe_exited = false
  s_remote.probe_closed = false
  s_remote.probe_status = -1
  s_remote.probe_job = job_start([
    daemon, 'probe', '--kind', s_remote.kind, '--target', s_remote.target,
    '--root', s_remote.root,
  ], {
    in_io: 'null', out_io: 'pipe', err_io: 'pipe', out_mode: 'nl', err_mode: 'nl',
    out_cb: (channel, line) => OnRuntimeProbeLine(generation, channel, line),
    err_cb: (channel, line) => OnRuntimeProbeError(generation, channel, line),
    close_cb: (channel) => OnRuntimeProbeClosed(generation, channel),
    exit_cb: (job, status) => OnRuntimeProbeExit(generation, job, status),
  })
enddef

def ShellLiteral(value: string): string
  return shellescape(value)
enddef

# 'json'   the runtime bridges JSON lines to the agent protocol
# 'exec'   an older runtime replaces itself with the transport
# 'legacy' no runtime: Vim drives ssh/docker and base64 itself
def TransportProtocol(): string
  var daemon = DaemonPath()
  if empty(daemon)
    return 'legacy'
  endif
  return RuntimeSupports('json') ? 'json' : 'exec'
enddef

def TargetCommand(kind: string, target: string, agent: string): list<string>
  var daemon = DaemonPath()
  var protocol = TransportProtocol()
  if protocol ==# 'json'
    var command = [daemon, 'agent', '--protocol', 'json', '--kind', kind,
      '--target', target, '--agent', agent]
    if filereadable(AgentSourcePath())
      extend(command, ['--agent-source', AgentSourcePath()])
    endif
    return command
  endif
  if protocol ==# 'exec'
    return [daemon, 'agent', '--kind', kind, '--target', target,
      '--agent', agent]
  endif
  var script = AgentBootstrapScript(agent)
  if kind ==# 'docker'
    return ['docker', 'exec', '-i', target, 'sh', '-c', script]
  endif
  # OpenSSH joins all arguments after the host into one login-shell command.
  # Quote the complete -c script so that boundary survives that re-serialization.
  return ['ssh', '-T', target, 'sh', '-c', ShellLiteral(script)]
enddef

def Disconnect(show_message: bool = true, reason: string = 'disconnect')
  if s_workspace_switch_timer > 0
    timer_stop(s_workspace_switch_timer)
    s_workspace_switch_timer = 0
  endif
  if empty(s_remote)
    CloseRemoteTree()
    ClearGlobals()
    return
  endif
  var remote = s_remote
  s_generation += 1
  s_remote = {}
  DeactivateWorkspace(remote)
  ClearGlobals()
  FailPending(remote, 'connection closed')
  var job = get(remote, 'job', v:null)
  if job != v:null && job_status(job) ==# 'run'
    job_stop(job, 'term')
  endif
  var probe_job = get(remote, 'probe_job', v:null)
  if probe_job != v:null && job_status(probe_job) ==# 'run'
    job_stop(probe_job, 'term')
  endif
  if show_message
    echomsg '[SimpleRemote] disconnected'
  endif
  Emit('SimpleRemoteDisconnected', {reason: reason})
enddef

# Whether this connection should put a tree on screen.  An option carried by
# the connection spec is an explicit answer and wins in both directions — a
# session restore asks for no tree, g:SimpleRemoteOpenWorkspace asks for one —
# and the global is the default when the spec says nothing.
def OpenTreeOnConnect(): bool
  var options = get(s_remote, 'options', {})
  if has_key(options, 'open_tree')
    return !!options.open_tree
  endif
  return !!get(g:, 'simpleremote_open_tree_on_connect', 1)
enddef

def FinishConnection(generation: number)
  if !IsCurrent(generation)
    return
  endif
  s_remote.state = 'ready'
  s_remote.tree_root = s_remote.root
  s_remote.connection_announced = true
  SetStatus(printf('%s:%s', s_remote.kind, s_remote.target))
  var mounting = ActivateWorkspace(generation)
  # A projected workspace announces SimpleRemoteWorkspaceChanged from inside
  # ActivateWorkspace().  Its handler has the same right to disconnect/switch
  # synchronously as the Connected handler below.
  if !IsCurrent(generation) || !IsReady()
    return
  endif
  RecordRecent()
  echomsg printf('[SimpleRemote] connected %s %s:%s',
    s_remote.kind, s_remote.target, s_remote.root)
  Emit('SimpleRemoteConnected', WorkspaceSnapshot())
  # User handlers are allowed to disconnect or switch workspace synchronously.
  # Everything below reads/mutates s_remote, so re-check ownership after the
  # event instead of draining the replacement connection's open queue (or
  # indexing an empty dictionary after a disconnect).
  if !IsCurrent(generation) || !IsReady()
    return
  endif
  if get(get(s_remote, 'runtime_probe', {}), 'status', -1) != -1
    # The probe raced ahead of the handshake; announce it now that listeners
    # may act on the workspace.
    Emit('SimpleRemoteRuntimeReady', WorkspaceSnapshot())
    if !IsCurrent(generation) || !IsReady()
      return
    endif
  endif

  var queued = copy(s_remote.open_queue)
  s_remote.open_queue = []
  for path in queued
    if !IsCurrent(generation) || !IsReady()
      return
    endif
    OpenRemote(path)
    if !IsCurrent(generation) || !IsReady()
      return
    endif
  endfor
  if OpenTreeOnConnect() && !mounting
    timer_start(0, (_) => {
      if IsCurrent(generation) && IsReady() && OpenTreeOnConnect()
        OpenWorkspaceTree()
      endif
    })
  endif
enddef

def FetchRemoteConfig(generation: number, Completion: func)
  if !IsCurrent(generation)
    return
  endif
  s_remote.config_epoch += 1
  var config_epoch = s_remote.config_epoch
  s_remote.state = 'configuring'
  var root = s_remote.root
  var config_path = root ==# '/' ? '/simplecc.json' : root .. '/simplecc.json'
  Send('read-config', {path: config_path}, (ok, body) => {
    if !IsCurrent(generation) || s_remote.config_epoch != config_epoch
      return
    endif
    if !ok
      if body =~# '^config not found:'
        unlet! g:vimrc_remote_simplecc_config
        echomsg '[VimrcRemote] no remote simplecc.json; using SimpleCC defaults'
        call(Completion, [true])
      else
        Error('[VimrcRemote] cannot load remote simplecc.json: ' .. body)
        call(Completion, [false])
      endif
      return
    endif
    var config = body
    try
      json_decode(config)
      g:vimrc_remote_simplecc_config = config
      echomsg '[VimrcRemote] remote SimpleCC config loaded'
    catch
      Error('[VimrcRemote] invalid remote simplecc.json: ' .. v:exception)
      call(Completion, [false])
      return
    endtry
    call(Completion, [true])
  })
enddef

def Connect(kind: string, target: string, root: string,
    options: dict<any> = {})
  if kind !=# 'ssh' && kind !=# 'docker'
    Error('[VimrcRemote] transport must be ssh or docker')
    return
  endif
  if empty(target) || target =~# '^-' || root !~# '^/'
    Error('[VimrcRemote] target is required and root must be absolute')
    return
  endif

  # A connection replaced by another is reported as 'reconnect', so consumers
  # such as SimpleFinder can keep their state instead of flashing an error
  # between the Disconnected and Connected events of a workspace switch.
  Disconnect(false, empty(s_remote) ? 'disconnect' : 'reconnect')
  s_connect_spec = copy(options)
  s_generation += 1
  var generation = s_generation
  var job = job_start(TargetCommand(kind, target, AgentPath()), {
    in_io: 'pipe', out_io: 'pipe', err_io: 'pipe', out_mode: 'nl',
    err_mode: 'nl',
    out_cb: (channel, line) => OnLine(generation, channel, line),
    err_cb: (channel, line) => OnError(generation, channel, line),
    exit_cb: (exited_job, status) => OnExit(generation, exited_job, status),
  })
  # job_start() returns a job object even when the command exits before this
  # check.  Only `run` owns a writable transport; accepting `dead` leaves a
  # connection that no exit callback can tear down because s_remote was not
  # installed when that callback fired.
  if job_status(job) !=# 'run'
    ClearGlobals()
    Error('[VimrcRemote] cannot start transport')
    return
  endif

  s_remote = {
    job: job,
    channel: job_getchannel(job),
    pending: {},
    listing_operations: {},
    stderr: [],
    generation: generation,
    kind: kind,
    target: target,
    root: root ==# '/' ? '/' : substitute(root, '/\+$', '', ''),
    state: 'connecting',
    handshake_ready: false,
    connection_announced: false,
    open_queue: [],
    config_epoch: 0,
    options: copy(options),
    local_root: '',
    workspace_mode: 'virtual',
    mount_owned: false,
    mount_job: v:null,
    protocol: TransportProtocol(),
  }
  s_last_spec = extend(copy(options), {
    kind: kind,
    target: target,
    root: s_remote.root,
  }, 'force')
  SetStatus(printf('connecting %s:%s', kind, target))
  unlet! g:vimrc_remote_workspace
  unlet! g:vimrc_remote_simplecc_config
  unlet! g:simpleremote_workspace
  Emit('SimpleRemoteConnecting', copy(s_last_spec))

  Send('ping', {}, (ok, body) => {
    if !IsCurrent(generation)
      return
    endif
    if !ok || body !=# PROTOCOL
      var reason = ok ? 'unsupported agent: ' .. body : body
      Error('[VimrcRemote] remote agent rejected connection: ' .. reason)
      Disconnect(false)
      return
    endif
    s_remote.handshake_ready = true
    g:vimrc_remote_workspace = {kind: kind, target: target, root: s_remote.root}
    # The environment probe and the config fetch are independent round trips;
    # starting the probe here means the Connected snapshot usually already
    # carries it, without making the connection wait for it.
    StartRuntimeProbe(generation)
    FetchRemoteConfig(generation, (_) => FinishConnection(generation))
  })
enddef

# Split a text payload into buffer lines.  With `drop_final_eol` the trailing
# empty item a final newline produces is removed, which is what a buffer wants;
# without it the item stays, which is how readfile(..., 'b') reports the same
# fact and how the write path expects to see it.
def RemoteLines(content: string, drop_final_eol: bool = true): list<string>
  var lines = split(content, "\n", 1)
  if drop_final_eol && content =~# "\n$" && len(lines) > 1 && lines[-1] ==# ''
    remove(lines, -1)
  endif
  return empty(lines) ? [''] : lines
enddef

# Language plugins (SimpleCC, SimpleTreesitter, SimpleMarkdown) attach on
# FileType, which only fires once the buffer has a filetype; a background read
# would otherwise leave a visible buffer undetected until it is re-entered.
def DetectRemoteFiletype(buf: number)
  if getbufvar(buf, '&filetype') !=# ''
    return
  endif
  if bufnr() == buf
    filetype detect
    return
  endif
  var winid = bufwinid(buf)
  if winid > 0
    win_execute(winid, 'filetype detect')
  endif
enddef

# A remote simplecc.json changed under an established connection.  SimpleCC
# listens for the event; the :SimpleCCRestart fallback keeps an older SimpleCC
# reloading the way it always did.
def AnnounceConfigChanged()
  var payload = {config: get(g:, 'vimrc_remote_simplecc_config', '')}
  if exists('#User#SimpleRemoteConfigChanged') == 1
    Emit('SimpleRemoteConfigChanged', payload)
  elseif exists(':SimpleCCRestart') == 2
    execute 'silent! SimpleCCRestart'
  endif
enddef

def OpenRemote(path: string)
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  if !IsReady()
    add(s_remote.open_queue, path)
    echomsg '[VimrcRemote] opening after connection is ready: ' .. path
    return
  endif

  var remote_path = path =~# '^/' ? path
        : s_remote.root ==# '/' ? '/' .. path : s_remote.root .. '/' .. path
  var uri = 'remote://' .. remote_path
  var existing = RemoteBufferFor(remote_path)
  var was_loaded = existing > 0 && bufloaded(existing)
  if existing > 0 && getbufvar(existing, '&modified')
        && get(getbufvar(existing, 'vimrc_remote', {}), 'generation', -1)
          != s_remote.generation
    Error('[VimrcRemote] refusing to replace modified buffer from an old connection')
    return
  endif
  if existing > 0 && bufname(existing) !=# uri
    # Renamed while it was hidden, so it still answers to the old name.  Show
    # it and give it the right one: :edit on the new name would otherwise make
    # a second buffer for the same file, and the two would overwrite each
    # other's saves.  Any unsaved work in it survives, which is the point.
    execute 'buffer ' .. existing
    SyncRemoteBufferName(existing)
  endif
  execute 'edit ' .. fnameescape(uri)
  if was_loaded
    ReadRemote(uri)
  endif
enddef

def JoinRemotePath(root: string, path: string): string
  return root ==# '/' ? '/' .. path : root .. '/' .. path
enddef

def ApplyRemoteRead(buf: number, generation: number, request_id: number,
    remote_path: string, uri: string, ok: bool, body: list<string>)
  if !IsCurrent(generation) || !bufexists(buf)
    return
  endif
  var pending = getbufvar(buf, 'vimrc_remote_read', {})
  if get(pending, 'request_id', -1) != request_id
    return
  endif
  setbufvar(buf, 'vimrc_remote_read', {})
  if !ok
    Error('[VimrcRemote] ' .. join(body, ' '))
    return
  endif
  if getbufvar(buf, 'changedtick', -1) != get(pending, 'tick', -2)
        || getbufvar(buf, '&modified')
    Error('[VimrcRemote] read result ignored because the buffer changed')
    return
  endif

  # A trailing empty item is how both readfile(..., 'b') and RemoteLines()
  # report a final newline; the buffer records it as 'endofline' instead.
  var lines = copy(body)
  var final_eol = len(lines) > 1 && lines[-1] ==# ''
  if final_eol
    remove(lines, -1)
  elseif empty(lines)
    lines = ['']
  endif
  var old_count = len(getbufline(buf, 1, '$'))
  setbufline(buf, 1, lines)
  if old_count > len(lines)
    deletebufline(buf, len(lines) + 1, old_count)
  endif
  setbufvar(buf, '&endofline', final_eol)
  setbufvar(buf, '&buftype', 'acwrite')
  setbufvar(buf, '&swapfile', 0)
  setbufvar(buf, 'vimrc_remote', {
    path: remote_path,
    uri: uri,
    generation: generation,
  })
  setbufvar(buf, '&modified', 0)
  DetectRemoteFiletype(buf)
  # `type` and `bufnr` are the documented payload (SimpleEditorConfig keys on
  # them); Emit adds event/status/time like every other SimpleRemote event.
  Emit('SimpleRemoteBufferRead', {
    type: 'buffer-read',
    bufnr: buf,
    path: remote_path,
    workspace: copy(get(g:, 'simpleremote_workspace', {})),
  })
enddef

# Above this many bytes a file is not read on sight.
#
# A remote read arrives as a single reply holding the whole file, so a large
# one costs the transport, the buffer and the request timeout at once -- and
# because the agent answers in order, everything queued behind it waits too.
# A workspace with a 150MB metrics CSV at the top of its listing made that
# concrete: opening the file ended in "request timed out: read", and so did
# the next few reads. Past the limit the buffer gets a hint instead and the
# file crosses only once the user asks for it. 0 opens everything on sight,
# the way it always did.
def LargeFileLimit(): number
  return max([0, get(g:, 'simpleremote_large_file_bytes', 10485760)])
enddef

def HumanBytes(size: number): string
  var units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
  var value = size * 1.0
  var unit = 0
  while value >= 1024.0 && unit < len(units) - 1
    value = value / 1024.0
    unit += 1
  endwhile
  return unit == 0 ? printf('%d B', size)
    : printf('%.1f %s', value, units[unit])
enddef

# stat is not in POSIX and its two dialects disagree on the flag, which is why
# the agent's own listing walks the same chain. wc -c reads the file to answer,
# so it is the last resort rather than the first choice.
#
# The agent runs a command with its stderr merged into its output, and a login
# shell that greets one -- "bash: warning: setlocale: LC_ALL: cannot change
# locale" is the one that found this -- prepends that greeting to the number.
# The answer is therefore printed on a line of its own and read back by name.
def SizeProbeCommand(remote_path: string): string
  var quoted = shellescape(remote_path)
  return 'printf ''simpleremote-size %s\n'' "$('
    .. 'stat -c %s ' .. quoted .. ' 2>/dev/null'
    .. ' || stat -f %z ' .. quoted .. ' 2>/dev/null'
    .. ' || wc -c < ' .. quoted .. ')"'
enddef

# The probed size, or -1 when the reply does not carry one.
def ParseProbedSize(body: string): number
  for line in split(body, '\n')
    var matched = matchlist(trim(line), '^simpleremote-size\s\+\(\d\+\)$')
    if !empty(matched)
      return str2nr(matched[1])
    endif
  endfor
  return -1
enddef

# A read whose size is known gets a timeout that size cannot outrun: the
# configured one covers a source file, not the hundred megabytes a user
# deliberately confirmed. Roughly 1 MiB/s, never below what is configured.
def ReadTimeoutFor(size: number): number
  var base = RequestTimeout()
  return base <= 0 || size <= 0 ? base : max([base, size / 1024])
enddef

def StartRemoteRead(buf: number, generation: number, remote_path: string,
    uri: string, timeout: number = -1)
  var request_id = 0
  request_id = Send('read', {path: remote_path}, (ok, body) =>
    ApplyRemoteRead(buf, generation, request_id, remote_path, uri, ok, body),
    true, timeout)
  if request_id >= 0
    setbufvar(buf, 'vimrc_remote_read', {
      request_id: request_id,
      tick: getbufvar(buf, 'changedtick', -1),
    })
  endif
enddef

# <CR> is the confirmation the hint offers. The buffer may not be on screen
# when the probe answers, so BufEnter installs it too.
def MapDeferredLoad(buf: number)
  var winid = bufwinid(buf)
  if winid > 0
    win_execute(winid,
      'nnoremap <buffer><silent><nowait> <CR> <Cmd>SimpleRemoteLoad<CR>')
  endif
enddef

def DeferLargeRead(buf: number, generation: number, remote_path: string,
    uri: string, size: number, limit: number)
  setbufvar(buf, 'vimrc_remote_read', {})
  setbufvar(buf, 'vimrc_remote_deferred', {
    path: remote_path,
    uri: uri,
    size: size,
    generation: generation,
  })
  var lines = [
    'SimpleRemote: this file has not been read.',
    '',
    '  ' .. remote_path,
    '  ' .. HumanBytes(size) .. ', over the ' .. HumanBytes(limit)
      .. ' g:simpleremote_large_file_bytes limit.',
    '',
    '  A remote read arrives as one reply holding the whole file, so this',
    '  one would cross the transport and land in this buffer in full, with',
    '  every request behind it waiting. Nothing has moved yet.',
    '',
    '  <CR>  or  :SimpleRemoteLoad    read it into this buffer anyway',
    '  :bdelete                       leave it unread',
  ]
  setbufvar(buf, '&modifiable', 1)
  var old_count = len(getbufline(buf, 1, '$'))
  setbufline(buf, 1, lines)
  if old_count > len(lines)
    deletebufline(buf, len(lines) + 1, old_count)
  endif
  # No filetype: the hint is not the file, and the language plugins that
  # attach on FileType have nothing to attach to yet.
  setbufvar(buf, '&filetype', '')
  setbufvar(buf, '&buftype', 'acwrite')
  setbufvar(buf, '&swapfile', 0)
  setbufvar(buf, '&modifiable', 0)
  setbufvar(buf, '&modified', 0)
  MapDeferredLoad(buf)
enddef

def FinishSizeProbe(buf: number, generation: number, request_id: number,
    remote_path: string, uri: string, limit: number, ok: bool, body: string)
  if !IsCurrent(generation) || !bufexists(buf)
    return
  endif
  if get(getbufvar(buf, 'vimrc_remote_read', {}), 'request_id', -1)
      != request_id
    return
  endif
  # A size that could not be read is no reason to hold the file back: the read
  # itself reports what is actually wrong with it, in the buffer waiting for it.
  var size = ok ? ParseProbedSize(body) : -1
  if size > limit
    DeferLargeRead(buf, generation, remote_path, uri, size, limit)
    return
  endif
  StartRemoteRead(buf, generation, remote_path, uri, ReadTimeoutFor(size))
enddef

def ReadRemote(uri: string)
  if empty(s_remote)
    # A session file re-edits remote:// buffers before the workspace exists;
    # the session restore reconnects and re-reads them, so stay quiet then.
    if !exists('g:SessionLoad')
      Error('[VimrcRemote] not connected')
    endif
    return
  endif
  var buf = bufnr()
  var generation = s_remote.generation
  var remote_path = substitute(uri, '^remote://', '', '')
  setbufvar(buf, 'vimrc_remote_deferred', {})
  var limit = LargeFileLimit()
  if limit <= 0
    StartRemoteRead(buf, generation, remote_path, uri)
    return
  endif
  var probe_id = 0
  probe_id = Send('exec', {command: SizeProbeCommand(remote_path)},
    (ok, body) => FinishSizeProbe(buf, generation, probe_id, remote_path,
      uri, limit, ok, body))
  if probe_id >= 0
    setbufvar(buf, 'vimrc_remote_read', {
      request_id: probe_id,
      tick: getbufvar(buf, 'changedtick', -1),
    })
  endif
enddef

def BufferHasFinalEol(buf: number): bool
  return !!(getbufvar(buf, '&endofline')
    || (getbufvar(buf, '&fixendofline') && !getbufvar(buf, '&binary')))
enddef

def FireRemoteWritePost(buf: number, generation: number, tick: number,
    final_eol: bool)
  var winid = bufwinid(buf)
  if winid > 0
    setbufvar(buf, 'vimrc_remote_writepost_pending', {})
    win_execute(winid, 'silent doautocmd <nomodeline> BufWritePost')
  else
    setbufvar(buf, 'vimrc_remote_writepost_pending', {
      generation: generation,
      tick: tick,
      final_eol: final_eol,
    })
  endif
enddef

def FinishRemoteWrite(buf: number, generation: number, tick: number,
    final_eol: bool, ok: bool, body: string)
  if !IsCurrent(generation) || !bufexists(buf)
    return
  endif
  if !ok
    Error('[VimrcRemote] save failed: ' .. body)
    return
  endif
  var same_tick = getbufvar(buf, 'changedtick', -1) == tick
  if same_tick && BufferHasFinalEol(buf) == final_eol
    setbufvar(buf, '&modified', 0)
    FireRemoteWritePost(buf, generation, tick, final_eol)
  else
    # 'endofline'/'fixendofline' can change without advancing changedtick.
    # Mark that byte-level difference pending just like a text edit.
    if same_tick
      setbufvar(buf, '&modified', 1)
    endif
    echomsg '[VimrcRemote] saved an older snapshot; newer changes remain'
  endif
  echomsg '[VimrcRemote] saved ' .. body
enddef

def WriteRemote(buf: number = bufnr())
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  var deferred = getbufvar(buf, 'vimrc_remote_deferred', {})
  if type(deferred) == v:t_dict && !empty(deferred)
    Error('[VimrcRemote] ' .. get(deferred, 'path', '')
      .. ' has not been read yet; :SimpleRemoteLoad first')
    return
  endif
  var info = getbufvar(buf, 'vimrc_remote', {})
  if empty(info)
    Error('[VimrcRemote] buffer is not backed by a remote file')
    return
  endif
  var generation = s_remote.generation
  if get(info, 'generation', -1) != generation
    Error('[VimrcRemote] buffer belongs to an old connection; reopen it first')
    return
  endif
  # BufWriteCmd suppresses Vim's own BufWritePre; fire it so trailing
  # whitespace trimming, format-on-save and friends see remote saves too.
  if buf == bufnr()
    silent doautocmd <nomodeline> BufWritePre
  endif
  var tick = getbufvar(buf, 'changedtick', -1)
  var final_eol = BufferHasFinalEol(buf)
  var encoded = EncodeLinesToBase64(getbufline(buf, 1, '$'), final_eol)
  Send('write', {path: info.path, content_b64: encoded}, (ok, body) =>
    FinishRemoteWrite(buf, generation, tick, final_eol, ok, body))
enddef

def RemoteExec(command: string)
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  var root = s_remote.root
  Send('exec', {command: 'cd ' .. shellescape(root) .. ' && ' .. command},
    (ok, body) => {
      if ok
        echomsg body
      else
        Error('[VimrcRemote] ' .. body)
      endif
    })
enddef

def RemoteFind(query: string)
  var root = s_remote.root
  var command = 'rg --files --hidden --glob ' .. shellescape('!.git/*')
        .. ' | rg --smart-case -- ' .. shellescape(query)
  Send('grep', {command: 'cd ' .. shellescape(root) .. ' && ' .. command},
    (ok, body) => {
      if !ok && !empty(body)
        Error('[VimrcRemote] ' .. body)
        return
      endif
      var entries: list<dict<any>> = []
      for line in split(body, '\n')
        if !empty(line)
          add(entries, {filename: 'remote://' .. JoinRemotePath(root, line)})
        endif
      endfor
      setqflist([], ' ', {title: 'Remote files: ' .. query, items: entries})
      copen
    })
enddef

def RemoteList(path: string)
  var remote_path = path ==# '' ? s_remote.root
        : path =~# '^/' ? path : JoinRemotePath(s_remote.root, path)
  SendDirectoryListing(remote_path, false, (ok, body, info) => {
    if !ok
      Error('[VimrcRemote] ' .. body)
      return
    endif
    var items: list<dict<any>> = []
    for line in split(body, '\n')
      var fields = split(line, "\t", 1)
      if len(fields) < 2 || empty(fields[0])
        continue
      endif
      var name = ListingName(fields[0], !!get(info, 'encoded', false))
      if empty(name)
        continue
      endif
      if fields[1] ==# 'd'
        # Directories are headings, not buffers.  Drill down explicitly with
        # :VimrcRemoteList path instead of opening a guaranteed read error.
        add(items, {text: name .. '/', valid: 0})
      else
        var child = JoinRemotePath(remote_path, name)
        add(items, {filename: 'remote://' .. child, text: name})
      endif
    endfor
    setqflist([], ' ', {title: 'Remote tree: ' .. remote_path, items: items})
    copen
  })
enddef

def RemoteHealth()
  var root = s_remote.root
  var command = 'cd ' .. shellescape(root)
        .. ' && { printf "host=%s\\npwd=%s\\n" "$(hostname 2>/dev/null || true)" "$PWD"; '
        .. 'command -v git || true; command -v rg || true; }'
  Send('exec', {command: command}, (ok, body) => {
    if ok
      echomsg '[VimrcRemote] ' .. body
    else
      Error('[VimrcRemote] ' .. body)
    endif
  })
enddef

def RemoteGit(command: string)
  var root = s_remote.root
  Send('exec', {command: 'cd ' .. shellescape(root) .. ' && git ' .. command},
    (ok, body) => {
      if !ok
        Error('[VimrcRemote] ' .. body)
        return
      endif
      var items: list<dict<any>> = []
      for line in split(body, '\n')
        if !empty(line)
          add(items, {text: line})
        endif
      endfor
      setqflist([], ' ', {title: 'Remote git ' .. command, items: items})
      copen
    })
enddef

# ---------------------------------------------------------------------------
# SimpleRemote workspace projection, discovery, and UI
# ---------------------------------------------------------------------------

def WorkspaceSnapshot(): dict<any>
  if empty(s_remote)
    return {}
  endif
  return {
    id: get(s_remote, 'generation', -1),
    kind: get(s_remote, 'kind', ''),
    target: get(s_remote, 'target', ''),
    root: get(s_remote, 'root', ''),
    tree_root: get(s_remote, 'tree_root', get(s_remote, 'root', '')),
    local_root: get(s_remote, 'local_root', ''),
    mode: get(s_remote, 'workspace_mode', 'virtual'),
    runtime: DaemonPath(),
    runtime_version: RuntimeVersion(),
    protocol: get(s_remote, 'protocol', 'legacy'),
    probe: get(s_remote, 'runtime_probe', {}),
    uri: 'remote://' .. get(s_remote, 'root', ''),
  }
enddef

def PublishWorkspace(mode: string, local_root: string = '')
  if empty(s_remote)
    return
  endif
  s_remote.workspace_mode = mode
  s_remote.local_root = local_root
  g:simpleremote_workspace = WorkspaceSnapshot()
enddef

def UnderRoot(path: string, root: string): bool
  if empty(path) || empty(root)
    return false
  endif
  var clean_root = root ==# '/' ? '/' : substitute(root, '/\+$', '', '')
  return path ==# clean_root
    || (clean_root ==# '/' ? path =~# '^/' : stridx(path, clean_root .. '/') == 0)
enddef

def NormalizeLocalRoot(path: string): string
  if empty(path)
    return ''
  endif
  var full = fnamemodify(expand(path), ':p')
  if !isdirectory(full)
    return ''
  endif
  return substitute(resolve(full), '[\\/]\+$', '', '')
enddef

def ShellCommand(argv: list<string>): string
  var quoted: list<string> = []
  for value in argv
    add(quoted, shellescape(value))
  endfor
  return join(quoted, ' ')
enddef

def DockerBindRoot(target: string, root: string): string
  if !executable('docker')
    return ''
  endif
  var output = systemlist(ShellCommand([
    'docker', 'inspect', '--format', '{{json .Mounts}}', target,
  ]))
  if v:shell_error != 0 || empty(output)
    return ''
  endif
  var mounts: any
  try
    mounts = json_decode(output[0])
  catch
    return ''
  endtry
  if type(mounts) != v:t_list
    return ''
  endif
  var best_destination = ''
  var best_source = ''
  for mount in mounts
    if type(mount) != v:t_dict
      continue
    endif
    var destination = substitute(get(mount, 'Destination', ''), '/\+$', '', '')
    var source = get(mount, 'Source', '')
    if empty(destination) || empty(source) || !UnderRoot(root, destination)
      continue
    endif
    if len(destination) > len(best_destination)
      best_destination = destination
      best_source = source
    endif
  endfor
  if empty(best_source)
    return ''
  endif
  var suffix = strpart(root, len(best_destination))
  return NormalizeLocalRoot(best_source .. suffix)
enddef

def ExplicitLocalRoot(): string
  var options = get(s_remote, 'options', {})
  var configured = get(options, 'local_root', '')
  if empty(configured)
    var roots = get(g:, 'simpleremote_local_roots', {})
    var key = printf('%s:%s:%s', s_remote.kind, s_remote.target, s_remote.root)
    if type(roots) == v:t_dict
      configured = get(roots, key, '')
    endif
  endif
  return NormalizeLocalRoot(configured)
enddef

def ProjectionStateDir(): string
  var context = get(g:, 'vimrc_context', {})
  var state = get(context, 'vim_state', expand('~/.local/state/vim'))
  return get(g:, 'simpleremote_state_dir', state .. '/simpleremote')
enddef

def EnsurePrivateDir(path: string): bool
  if mkdir(path, 'p', 0o700) == 0 && !isdirectory(path)
    return false
  endif
  setfperm(path, 'rwx------')
  return isdirectory(path)
enddef

def ActivateProjection(local_root: string, mode: string, owned: bool = false)
  if empty(s_remote) || !isdirectory(local_root)
    return
  endif
  if empty(s_previous_cwd)
    s_previous_cwd = getcwd()
  endif
  s_remote.mount_owned = owned
  PublishWorkspace(mode, local_root)
  if get(g:, 'simpleremote_change_directory', 'tab') ==# 'global'
    execute 'silent! cd ' .. fnameescape(local_root)
  elseif get(g:, 'simpleremote_change_directory', 'tab') !=# 'none'
    execute 'silent! tcd ' .. fnameescape(local_root)
  endif
  Emit('SimpleRemoteWorkspaceChanged', WorkspaceSnapshot())
enddef

def OnSshfsExit(generation: number, mountpoint: string,
    _job: any, status: number)
  if !IsCurrent(generation)
    return
  endif
  s_remote.mount_job = v:null
  if status == 0 && isdirectory(mountpoint)
    ActivateProjection(mountpoint, 'sshfs', true)
    echomsg '[SimpleRemote] SSHFS workspace ready: ' .. mountpoint
    if OpenTreeOnConnect()
      timer_start(0, (_) => {
        if IsCurrent(generation) && IsReady() && OpenTreeOnConnect()
          OpenWorkspaceTree()
        endif
      })
    endif
    return
  endif
  PublishWorkspace('virtual')
  echomsg '[SimpleRemote] SSHFS unavailable; using virtual workspace'
  # The mount failed, so the workspace is virtual after all: say so, or a
  # listener that acted on 'mounting' keeps waiting for a projection.
  Emit('SimpleRemoteWorkspaceChanged', WorkspaceSnapshot())
  if OpenTreeOnConnect()
    timer_start(0, (_) => {
      if IsCurrent(generation) && IsReady() && OpenTreeOnConnect()
        OpenWorkspaceTree()
      endif
    })
  endif
enddef

def StartSshfs(generation: number): bool
  if s_remote.kind !=# 'ssh' || !executable('sshfs')
    return false
  endif
  var workspace_mode = get(g:, 'simpleremote_workspace_mode', 'auto')
  var sshfs_mode = get(g:, 'simpleremote_use_sshfs', 'auto')
  if workspace_mode ==# 'virtual' || sshfs_mode ==# 'never' || sshfs_mode == 0
    return false
  endif
  var key = substitute(s_remote.target, '[^0-9A-Za-z_.-]', '_', 'g')
    .. '-' .. strpart(sha256(s_remote.root), 0, 12)
  var mountpoint = ProjectionStateDir() .. '/mounts/' .. key
  if !EnsurePrivateDir(ProjectionStateDir()) || !EnsurePrivateDir(mountpoint)
    return false
  endif
  if executable('mountpoint')
    system('mountpoint -q ' .. shellescape(mountpoint))
    if v:shell_error == 0
      ActivateProjection(mountpoint, 'sshfs', false)
      return false
    endif
  endif
  PublishWorkspace('mounting')
  var job = job_start([
    'sshfs', s_remote.target .. ':' .. s_remote.root, mountpoint,
    '-o', 'reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,BatchMode=yes',
  ], {
    in_io: 'null', out_io: 'null', err_io: 'pipe', err_mode: 'nl',
    err_cb: (channel, line) => OnError(generation, channel, line),
    exit_cb: (exited_job, status) =>
      OnSshfsExit(generation, mountpoint, exited_job, status),
  })
  if job_status(job) ==# 'fail'
    PublishWorkspace('virtual')
    return false
  endif
  s_remote.mount_job = job
  return true
enddef

def ActivateWorkspace(generation: number): bool
  PublishWorkspace('virtual')
  var local_root = ExplicitLocalRoot()
  if empty(local_root) && s_remote.kind ==# 'docker'
        && get(g:, 'simpleremote_workspace_mode', 'auto') !=# 'virtual'
    local_root = DockerBindRoot(s_remote.target, s_remote.root)
  endif
  if !empty(local_root)
    ActivateProjection(local_root,
      s_remote.kind ==# 'docker' ? 'docker-bind' : 'local-map')
    return false
  endif
  return StartSshfs(generation)
enddef

def CloseRemoteTree()
  var buf = get(s_tree, 'buf', -1)
  if buf > 0 && bufexists(buf)
    var winid = bufwinid(buf)
    if winid > 0
      win_execute(winid, 'silent! close')
    endif
  endif
  s_tree = {}
enddef

def DeactivateWorkspace(remote: dict<any>)
  CloseRemoteTree()
  var mount_job = get(remote, 'mount_job', v:null)
  if mount_job != v:null && job_status(mount_job) ==# 'run'
    job_stop(mount_job, 'term')
  endif
  var local_root = get(remote, 'local_root', '')
  if get(remote, 'mount_owned', false) && !empty(local_root)
    if executable('fusermount3')
      system(ShellCommand(['fusermount3', '-u', local_root]))
    elseif executable('fusermount')
      system(ShellCommand(['fusermount', '-u', local_root]))
    elseif executable('umount')
      system(ShellCommand(['umount', local_root]))
    endif
  endif
  if !empty(s_previous_cwd) && isdirectory(s_previous_cwd)
        && (getcwd() ==# local_root || UnderRoot(getcwd(), local_root))
    execute 'silent! tcd ' .. fnameescape(s_previous_cwd)
  endif
  s_previous_cwd = ''
enddef

def HistoryFile(): string
  EnsurePrivateDir(ProjectionStateDir())
  return get(g:, 'simpleremote_history_file',
    ProjectionStateDir() .. '/recent.json')
enddef

def RecentSpecs(): list<dict<any>>
  var file = HistoryFile()
  if !filereadable(file)
    return []
  endif
  try
    var decoded = json_decode(join(readfile(file), "\n"))
    return type(decoded) == v:t_list ? decoded : []
  catch
    return []
  endtry
enddef

def RecordRecent()
  if empty(s_remote)
    return
  endif
  var current = {
    name: get(s_remote.options, 'name', ''),
    kind: s_remote.kind,
    target: s_remote.target,
    root: s_remote.root,
    local_root: get(s_remote.options, 'local_root', ''),
  }
  var key = printf('%s\t%s\t%s', current.kind, current.target, current.root)
  var recent: list<dict<any>> = [current]
  for spec in RecentSpecs()
    if type(spec) != v:t_dict
      continue
    endif
    var other = printf('%s\t%s\t%s', get(spec, 'kind', ''),
      get(spec, 'target', ''), get(spec, 'root', ''))
    if other !=# key
      add(recent, spec)
    endif
    if len(recent) >= get(g:, 'simpleremote_recent_limit', 12)
      break
    endif
  endfor
  try
    mkdir(fnamemodify(HistoryFile(), ':h'), 'p', 0o700)
    writefile([json_encode(recent)], HistoryFile())
  catch
    # History is convenience state and must never break a live connection.
  endtry
enddef

def NormalizeSpec(value: any, name: string = ''): dict<any>
  if type(value) == v:t_string
    return {name: name, kind: 'ssh', target: value, root: ''}
  endif
  if type(value) != v:t_dict
    return {}
  endif
  var spec = copy(value)
  if !empty(name) && empty(get(spec, 'name', ''))
    spec.name = name
  endif
  var kind = get(spec, 'kind', 'ssh')
  var target = get(spec, 'target', '')
  if type(kind) != v:t_string || type(target) != v:t_string
        || (kind !=# 'ssh' && kind !=# 'docker') || empty(target)
    return {}
  endif
  spec.kind = kind
  spec.target = target
  spec.root = get(spec, 'root', '')
  return spec
enddef

def ConfiguredProfiles(): list<dict<any>>
  var profiles = get(g:, 'simpleremote_profiles', [])
  var result: list<dict<any>> = []
  if type(profiles) == v:t_dict
    for [name, value] in items(profiles)
      var spec = NormalizeSpec(value, name)
      if !empty(spec)
        add(result, spec)
      endif
    endfor
  elseif type(profiles) == v:t_list
    for value in profiles
      var spec = NormalizeSpec(value)
      if !empty(spec)
        add(result, spec)
      endif
    endfor
  endif
  return result
enddef

def SshSpecs(): list<dict<any>>
  var result: list<dict<any>> = []
  var files = get(g:, 'simpleremote_ssh_config_files', [expand('~/.ssh/config')])
  for file in files
    var expanded = expand(file)
    if !filereadable(expanded)
      continue
    endif
    for line in readfile(expanded)
      var match = matchlist(line, '^\s*Host\s\+\(.*\)$')
      if empty(match)
        continue
      endif
      for host in split(match[1])
        if host !~# '[*?!]' && host !~# '^-' && !empty(host)
          add(result, {kind: 'ssh', target: host, root: '', source: 'ssh'})
        endif
      endfor
    endfor
  endfor
  return result
enddef

def DockerSpecs(): list<dict<any>>
  if !executable('docker')
    return []
  endif
  var lines = systemlist('docker ps --format '
    .. shellescape('{{.Names}}\t{{.Image}}'))
  if v:shell_error != 0
    return []
  endif
  var result: list<dict<any>> = []
  for line in lines
    var fields = split(line, "\t", 1)
    if !empty(fields) && !empty(fields[0])
      add(result, {
        kind: 'docker',
        target: fields[0],
        root: '',
        detail: len(fields) > 1 ? fields[1] : '',
        source: 'docker',
      })
    endif
  endfor
  return result
enddef

def CandidateSpecs(kinds: list<string> = []): list<dict<any>>
  var result: list<dict<any>> = []
  var seen: dict<bool> = {}
  var candidates = ConfiguredProfiles() + RecentSpecs() + SshSpecs() + DockerSpecs()
  for value in candidates
    var spec = NormalizeSpec(value)
    if empty(spec) || (!empty(kinds) && index(kinds, spec.kind) < 0)
      continue
    endif
    var key = spec.kind .. "\t" .. spec.target .. "\t" .. get(spec, 'root', '')
    if has_key(seen, key)
      continue
    endif
    seen[key] = true
    add(result, spec)
  endfor
  return result
enddef

def SpecLabel(spec: dict<any>): string
  var name = get(spec, 'name', '')
  var root = get(spec, 'root', '')
  var detail = get(spec, 'detail', '')
  return printf('[%s] %s%s%s', spec.kind,
    empty(name) ? spec.target : name .. '  ' .. spec.target,
    empty(root) ? '' : '  ' .. root,
    empty(detail) ? '' : '  ' .. detail)
enddef

def ConnectSpec(spec: dict<any>)
  var root = get(spec, 'root', '')
  if empty(root)
    root = input(printf('%s %s folder: ', spec.kind, spec.target),
      get(g:, 'simpleremote_default_root', '/'))
  endif
  if empty(root)
    return
  endif
  if root !~# '^/'
    Error('[SimpleRemote] workspace folder must be absolute')
    return
  endif
  Connect(spec.kind, spec.target, root, spec)
enddef

def SelectCandidate(specs: list<dict<any>>, result: number)
  if result <= 0 || result > len(specs)
    return
  endif
  ConnectSpec(specs[result - 1])
enddef

def PickTargets(kinds: list<string> = [])
  var specs = CandidateSpecs(kinds)
  if empty(specs)
    var kind_choice = confirm('SimpleRemote transport', "&SSH\n&Docker\n&Cancel", 1)
    if kind_choice == 3 || kind_choice == 0
      return
    endif
    var kind = kind_choice == 1 ? 'ssh' : 'docker'
    var target = input(kind .. ' target: ')
    if !empty(target)
      ConnectSpec({kind: kind, target: target, root: ''})
    endif
    return
  endif
  var labels = mapnew(specs, (_, spec) => SpecLabel(spec))
  if exists('*popup_menu') == 1
    popup_menu(labels, {
      title: ' SimpleRemote targets ',
      callback: (_id, result) => SelectCandidate(specs, result),
      maxheight: min([18, &lines - 4]),
      minwidth: min([72, &columns - 4]),
    })
  else
    SelectCandidate(specs, inputlist(['SimpleRemote targets:'] + labels))
  endif
enddef

def RemoteParent(path: string): string
  if path ==# '/'
    return '/'
  endif
  var parent = substitute(path, '/[^/]\+$', '', '')
  return empty(parent) ? '/' : parent
enddef

def TreeIcons(): dict<any>
  var icons = get(g:, 'simpleremote_tree_use_nerdfont', 1) ? {
    root: '󰉋', ssh: '󰣀', docker: '', dir: '', dir_open: '',
    file: '', link: '', loading: '', error: '',
    branch: '├─ ', last: '└─ ', vertical: '│  ', blank: '   ',
  } : {
    root: '#', ssh: '@', docker: 'D', dir: '>', dir_open: 'v',
    file: '-', link: '@', loading: '~', error: '!',
    branch: '|- ', last: '`- ', vertical: '|  ', blank: '   ',
  }
  return extend(icons, get(g:, 'simpleremote_tree_icons', {}), 'force')
enddef

def TreeFileIcon(name: string, icons: dict<any>): string
  if !get(g:, 'simpleremote_tree_show_file_icons', 1)
    return icons.file
  endif
  var special = {
    'readme.md': '󰂺', 'license': '', 'makefile': '',
    'dockerfile': '', '.gitignore': '', '.gitattributes': '',
  }
  var lower = tolower(name)
  if has_key(special, lower)
    return special[lower]
  endif
  var map = {
    vim: '', lua: '', py: '', js: '', jsx: '', ts: '', tsx: '',
    rs: '', go: '', c: '', h: '', cpp: '', cc: '', hpp: '',
    java: '', rb: '', php: '', sh: '', bash: '', zsh: '',
    html: '', css: '', scss: '', json: '', yaml: '', yml: '',
    toml: '', xml: '󰗀', md: '', txt: '󰈙', pdf: '',
    png: '', jpg: '', jpeg: '', gif: '', svg: '󰜡', webp: '',
    zip: '', gz: '', tar: '', xz: '', lock: '󰌾',
  }
  var override = get(g:, 'simpleremote_tree_file_icon_map', {})
  if type(override) == v:t_dict
    extend(map, override, 'force')
  endif
  var ext = tolower(fnamemodify(name, ':e'))
  return get(map, ext, icons.file)
enddef

def TreeEllipsize(value: string, width: number, from_left: bool = false): string
  if width <= 1 || strdisplaywidth(value) <= width
    return value
  endif
  var keep = max([1, width - 1])
  return from_left
    ? '…' .. strcharpart(value, max([0, strchars(value) - keep]))
    : strcharpart(value, 0, keep) .. '…'
enddef

def TreeWidth(): number
  var winid = get(s_tree, 'buf', -1)->bufwinid()
  return winid > 0 ? max([20, winwidth(winid) - 2])
    : max([20, get(g:, 'simpleremote_tree_width', 40) - 2])
enddef

def TreeHeader(): list<string>
  var icons = TreeIcons()
  var width = TreeWidth()
  var root = get(s_tree, 'root', get(s_remote, 'root', '/'))
  var title = root ==# '/' ? '/' : fnamemodify(root, ':t')
  var profile = get(get(s_remote, 'options', {}), 'name', '')
  var target = empty(profile) ? substitute(s_remote.target, '^[^@]\+@', '', '')
    : profile
  var transport_icon = s_remote.kind ==# 'docker' ? icons.docker : icons.ssh
  return [
    ' ' .. icons.root .. '  ' .. TreeEllipsize(title, width - 4),
    ' ' .. transport_icon .. '  ' .. toupper(s_remote.kind) .. ' · '
      .. TreeEllipsize(target, width - 10),
    '    ' .. TreeEllipsize(root, width - 4, true),
    '',
  ]
enddef

def TreeIgnored(name: string): bool
  if !get(g:, 'simpleremote_tree_show_hidden', 1) && name =~# '^\.'
    return true
  endif
  for pattern in get(g:, 'simpleremote_tree_ignore', [])
    if type(pattern) == v:t_string && name =~# glob2regpat(pattern)
      return true
    endif
  endfor
  return false
enddef

const TREE_SORT_MODES = ['name', 'extension', 'mtime', 'size']

def TreeSortMode(): string
  var mode = get(s_tree, 'sort', get(g:, 'simpleremote_tree_sort', 'name'))
  return index(TREE_SORT_MODES, mode) >= 0 ? mode : 'name'
enddef

def TreeTextCompare(left: string, right: string): number
  var a = tolower(left)
  var b = tolower(right)
  return a ==# b ? (left ==# right ? 0 : left <# right ? -1 : 1)
    : a <# b ? -1 : 1
enddef

def TreeNodeCompare(left: dict<any>, right: dict<any>): number
  var left_dir = left.type ==# 'd'
  var right_dir = right.type ==# 'd'
  if left_dir != right_dir
    return left_dir ? -1 : 1
  endif
  var mode = TreeSortMode()
  var result = 0
  if mode ==# 'extension'
    result = TreeTextCompare(fnamemodify(left.name, ':e'),
      fnamemodify(right.name, ':e'))
  elseif mode ==# 'mtime' || mode ==# 'size'
    var a = get(left, mode, -1)
    var b = get(right, mode, -1)
    if a != b
      # Metadata modes show newest/largest first, matching SimpleTree.
      result = a > b ? -1 : 1
    endif
  endif
  if result == 0
    result = TreeTextCompare(left.name, right.name)
  endif
  return get(s_tree, 'sort_reverse', false) ? -result : result
enddef

def ParseTreeDirectory(path: string, body: string,
    encoded: bool = false): list<dict<any>>
  var nodes: list<dict<any>> = []
  for line in split(body, '\n')
    var fields = split(line, "\t", 1)
    if len(fields) < 2 || empty(fields[0])
      continue
    endif
    var name = ListingName(fields[0], encoded)
    if empty(name) || TreeIgnored(name)
      continue
    endif
    var node = {
      name: name,
      path: JoinRemotePath(path, name),
      type: fields[1],
      size: len(fields) > 2 ? str2nr(fields[2]) : -1,
      mtime: len(fields) > 3 ? str2nr(fields[3]) : -1,
    }
    add(nodes, node)
  endfor
  sort(nodes, TreeNodeCompare)
  return nodes
enddef

def TreeStatusRank(status: string): number
  return get({conflict: 5, deleted: 4, staged: 3, modified: 2, untracked: 1},
    status, 0)
enddef

def TreeGitStatus(code: string): string
  if code =~# 'U' || code ==# 'AA' || code ==# 'DD'
    return 'conflict'
  elseif code ==# '??'
    return 'untracked'
  elseif code =~# 'D'
    return 'deleted'
  elseif strpart(code, 0, 1) !=# ' '
    return 'staged'
  elseif strpart(code, 1, 1) !=# ' '
    return 'modified'
  endif
  return ''
enddef

def OnTreeGit(generation: number, epoch: number, ok: bool, body: string)
  if !ok || !IsCurrent(generation) || empty(s_tree)
        || get(s_tree, 'epoch', -1) != epoch
    return
  endif
  var root = s_tree.root
  var statuses: dict<string> = {}
  var ignored: dict<bool> = {}
  for line in split(body, '\n', 1)
    if len(line) < 4
      continue
    endif
    var code = strpart(line, 0, 2)
    var relative = strpart(line, 3)
    if empty(relative)
      continue
    endif
    if relative =~# ' -> '
      relative = split(relative, ' -> ', 1)[-1]
    endif
    relative = substitute(relative, '/\+$', '', '')
    var path = JoinRemotePath(root, relative)
    if code ==# '!!'
      ignored[path] = true
      continue
    endif
    var status = TreeGitStatus(code)
    if empty(status)
      continue
    endif
    statuses[path] = status
    var parent = RemoteParent(path)
    while parent !=# root && UnderRoot(parent, root)
      if TreeStatusRank(status) > TreeStatusRank(get(statuses, parent, ''))
        statuses[parent] = status
      endif
      parent = RemoteParent(parent)
    endwhile
  endfor
  s_tree.git = statuses
  s_tree.git_ignored = ignored
  RenderRemoteTree(s_tree.buf)
enddef

def LoadTreeGit()
  if (!get(g:, 'simpleremote_tree_show_git_status', 1)
      && !get(s_tree, 'git_ignore', true)) || empty(s_tree)
    return
  endif
  var generation = s_remote.generation
  var epoch = s_tree.epoch
  var root = s_tree.root
  var command = 'cd ' .. shellescape(root)
    .. ' && if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then '
    .. 'git -c core.quotepath=false status --porcelain=v1 '
    .. '--untracked-files=all --ignored=matching; fi'
  Send('exec', {command: command},
    (ok, body) => OnTreeGit(generation, epoch, ok, body))
enddef

def TreePathGitIgnored(path: string): bool
  if !get(s_tree, 'git_ignore', true)
    return false
  endif
  var current = path
  var ignored = get(s_tree, 'git_ignored', {})
  while UnderRoot(current, s_tree.root)
    if has_key(ignored, current)
      return true
    endif
    if current ==# s_tree.root
      break
    endif
    current = RemoteParent(current)
  endwhile
  return false
enddef

def TreeFilterMatches(node: dict<any>): bool
  var query = tolower(get(s_tree, 'filter_query', ''))
  if empty(query) || stridx(tolower(node.name), query) >= 0
        || stridx(tolower(node.path), query) >= 0
    return true
  endif
  if node.type !=# 'd'
    return false
  endif
  for child in get(get(s_tree, 'cache', {}), node.path, [])
    if !TreePathGitIgnored(child.path) && TreeFilterMatches(child)
      return true
    endif
  endfor
  return false
enddef

def TreeVisibleChildren(parent: string): list<dict<any>>
  var children: list<dict<any>> = []
  for node in get(get(s_tree, 'cache', {}), parent, [])
    if !TreePathGitIgnored(node.path) && TreeFilterMatches(node)
      add(children, node)
    endif
  endfor
  return children
enddef

def TreePrefix(ancestors: list<bool>, last: bool, icons: dict<any>): string
  var prefix = ''
  for ancestor_last in ancestors
    prefix ..= ancestor_last ? icons.blank : icons.vertical
  endfor
  return prefix .. (last ? icons.last : icons.branch)
enddef

def TreeBadge(status: string): string
  return get({conflict: '!', deleted: 'D', staged: '+', modified: 'M',
    untracked: '?'}, status, '')
enddef

def AddTreeAuxLine(prefix: string, text: string, lines: list<string>,
    nodes: list<dict<any>>)
  add(lines, prefix .. text)
  add(nodes, {})
enddef

def AppendTreeChildren(parent: string, ancestors: list<bool>,
    lines: list<string>, nodes: list<dict<any>>)
  var icons = TreeIcons()
  var children = TreeVisibleChildren(parent)
  for index in range(0, len(children) - 1)
    var node = copy(children[index])
    var last = index == len(children) - 1
    var prefix = TreePrefix(ancestors, last, icons)
    var expanded = node.type ==# 'd' && has_key(s_tree.expanded, node.path)
    var icon = node.type ==# 'd' ? (expanded ? icons.dir_open : icons.dir)
      : node.type ==# 'l' ? icons.link : TreeFileIcon(node.name, icons)
    var suffix = node.type ==# 'd' ? '/' : node.type ==# 'l' ? '@' : ''
    var status = get(get(s_tree, 'git', {}), node.path, '')
    var body = prefix .. icon .. ' ' .. node.name .. suffix
    var badge = TreeBadge(status)
    if !empty(badge)
      body ..= repeat(' ', max([2, TreeWidth() - strdisplaywidth(body) - 1])) .. badge
    endif
    if TreeBookmarked(node.path)
      body ..= ' ' .. get(g:, 'simpleremote_tree_bookmark_symbol', '★')
    endif
    if has_key(get(s_tree, 'marked', {}), node.path)
      body ..= ' ' .. get(g:, 'simpleremote_tree_mark_symbol', '✓')
    endif
    node.expanded = expanded
    node.parent = parent
    node.status = status
    add(lines, body)
    add(nodes, node)
    if !expanded
      continue
    endif
    var child_prefix = ''
    for ancestor_last in ancestors + [last]
      child_prefix ..= ancestor_last ? icons.blank : icons.vertical
    endfor
    if has_key(get(s_tree, 'errors', {}), node.path)
      AddTreeAuxLine(child_prefix .. icons.error .. ' ',
        s_tree.errors[node.path], lines, nodes)
    elseif has_key(get(s_tree, 'cache', {}), node.path)
      AppendTreeChildren(node.path, ancestors + [last], lines, nodes)
    else
      AddTreeAuxLine(child_prefix .. icons.loading .. ' ', 'loading…', lines, nodes)
    endif
  endfor
enddef

def SetupRemoteTreeSyntax()
  highlight default link SimpleRemoteTreeTitle Title
  highlight default link SimpleRemoteTreeMeta Comment
  highlight default link SimpleRemoteTreePath Directory
  highlight default link SimpleRemoteTreeGuide NonText
  highlight default link SimpleRemoteTreeDirectory Directory
  highlight default link SimpleRemoteTreeHidden Comment
  highlight default link SimpleRemoteTreeLoading WarningMsg
  highlight default link SimpleRemoteTreeGitModified WarningMsg
  highlight default link SimpleRemoteTreeGitStaged DiffAdd
  highlight default link SimpleRemoteTreeGitUntracked Comment
  highlight default link SimpleRemoteTreeGitConflict ErrorMsg
  highlight default link SimpleRemoteTreeGitDeleted DiffDelete
  highlight default link SimpleRemoteTreeMarked Special
  highlight default link SimpleRemoteTreeBookmark Special
  syntax clear
  syntax match SimpleRemoteTreeTitle /\%1l.*/
  syntax match SimpleRemoteTreeMeta /\%2l.*/
  syntax match SimpleRemoteTreePath /\%3l.*/
  syntax match SimpleRemoteTreeGuide /[│├└─]/
  syntax match SimpleRemoteTreeDirectory /^.*\/\%(\s\+[M+?!D]\)\?$/
  syntax match SimpleRemoteTreeHidden /\s\zs\.[^/[:space:]]*/
  syntax match SimpleRemoteTreeLoading /loading…$/
  syntax match SimpleRemoteTreeGitModified /M$/
  syntax match SimpleRemoteTreeGitStaged /+$/
  syntax match SimpleRemoteTreeGitUntracked /?$/
  syntax match SimpleRemoteTreeGitConflict /!$/
  syntax match SimpleRemoteTreeGitDeleted /D$/
  execute 'syntax match SimpleRemoteTreeMarked /'
    .. escape(get(g:, 'simpleremote_tree_mark_symbol', '✓'), '/') .. '$/'
  execute 'syntax match SimpleRemoteTreeBookmark /'
    .. escape(get(g:, 'simpleremote_tree_bookmark_symbol', '★'), '/') .. '\%($\|\s\)/'
enddef

def RenderRemoteTree(buf: number)
  if !bufexists(buf) || get(s_tree, 'buf', -1) != buf
    return
  endif
  var lines = TreeHeader()
  var nodes: list<dict<any>> = [{}, {}, {}, {}]
  var root = s_tree.root
  var icons = TreeIcons()
  if has_key(get(s_tree, 'errors', {}), root)
    AddTreeAuxLine(icons.error .. ' ', s_tree.errors[root], lines, nodes)
  elseif has_key(get(s_tree, 'cache', {}), root)
    AppendTreeChildren(root, [], lines, nodes)
  else
    AddTreeAuxLine(icons.loading .. ' ', 'loading…', lines, nodes)
  endif
  var focus_path = get(s_tree, 'reveal', '')
  var winid = bufwinid(buf)
  if empty(focus_path) && winid > 0
    var old_line = getcurpos(winid)[1] - 1
    var old_nodes = getbufvar(buf, 'simpleremote_tree_nodes', [])
    if old_line >= 0 && old_line < len(old_nodes)
      focus_path = get(old_nodes[old_line], 'path', '')
    endif
  endif
  setbufvar(buf, '&modifiable', 1)
  setbufline(buf, 1, lines)
  var old_count = len(getbufline(buf, 1, '$'))
  if old_count > len(lines)
    deletebufline(buf, len(lines) + 1, old_count)
  endif
  setbufvar(buf, 'simpleremote_tree_nodes', nodes)
  setbufvar(buf, 'simpleremote_tree_path', root)
  setbufvar(buf, '&modifiable', 0)
  if !empty(focus_path)
    var focused = false
    for index in range(0, len(nodes) - 1)
      if get(nodes[index], 'path', '') ==# focus_path
        if winid > 0
          win_execute(winid, printf('cursor(%d, 1)', index + 1))
        endif
        focused = true
        break
      endif
    endfor
    # Git metadata and the directory listing race independently.  Keep the
    # reveal target until a render actually contains it; clearing it after an
    # earlier loading/metadata render leaves the cursor on the header forever.
    if focused
      s_tree.reveal = ''
    endif
  endif
enddef

def OnTreeList(generation: number, epoch: number, buf: number, path: string,
    metadata_requested: bool, ok: bool, body: string, info: dict<any>)
  if !IsCurrent(generation) || !bufexists(buf) || empty(s_tree)
        || s_tree.buf != buf || s_tree.epoch != epoch
    return
  endif
  if has_key(s_tree.loading, path)
    remove(s_tree.loading, path)
  endif
  if ok
    if metadata_requested
      s_tree.metadata_supported = !!get(info, 'metadata', false) ? 1 : 0
    endif
    s_tree.cache[path] = ParseTreeDirectory(path, body,
      !!get(info, 'encoded', false))
    if has_key(s_tree.errors, path)
      remove(s_tree.errors, path)
    endif
  else
    s_tree.errors[path] = body
  endif
  RenderRemoteTree(buf)
enddef

def LoadTreeDirectory(path: string, force: bool = false)
  if !IsReady() || empty(s_tree)
    return
  endif
  if !force && has_key(s_tree.cache, path)
    RenderRemoteTree(s_tree.buf)
    return
  endif
  if has_key(s_tree.loading, path)
    return
  endif
  s_tree.loading[path] = true
  var generation = s_remote.generation
  var epoch = s_tree.epoch
  var buf = s_tree.buf
  var metadata = index(['mtime', 'size'], TreeSortMode()) >= 0
    && get(s_tree, 'metadata_supported', -1) != 0
  RenderRemoteTree(buf)
  SendDirectoryListing(path, metadata,
    (ok, body, info) => OnTreeList(
      generation, epoch, buf, path, metadata, ok, body, info))
enddef

def LoadRemoteTree(path: string)
  if !IsReady() || empty(s_tree)
    return
  endif
  if get(s_tree, 'root', '') !=# path
    s_tree.epoch += 1
    s_tree.root = path
    s_tree.cache = {}
    s_tree.loading = {}
    s_tree.errors = {}
    s_tree.git = {}
    s_tree.git_ignored = {}
    s_tree.marked = {}
    s_tree.expanded = {path: true}
  endif
  LoadTreeDirectory(path)
  LoadTreeGit()
enddef

def NormalizeTreeRoot(path: string): string
  if empty(path) || path !~# '^/'
    return ''
  endif
  var normalized = substitute(simplify(path), '/\+$', '', '')
  return empty(normalized) ? '/' : normalized
enddef

def SimpleTreeVisible(): bool
  for window in getwininfo()
    if getbufvar(window.bufnr, '&filetype') ==# 'simpletree'
      return true
    endif
  endfor
  return false
enddef

def SetSimpleTreeRoot(path: string): bool
  if exists('*simpletree#ExternalSetRoot') != 1
    return false
  endif
  # On an SSHFS mount inotify never reports remote-side changes and git
  # status walks the network; newer SimpleTree accepts per-root options that
  # switch both off so its idle mtime polling takes over.
  if get(s_remote, 'workspace_mode', '') ==# 'sshfs'
    try
      return simpletree#ExternalSetRoot(path, 'simpleremote',
        {watch: false, git: false})
    catch
    endtry
  endif
  try
    # New SimpleTree versions publish this source in RootChanged, allowing the
    # listener below to distinguish our projection echo from a user re-root.
    return simpletree#ExternalSetRoot(path, 'simpleremote')
  catch
    # Keep mixed-version installations useful while SimpleTree rolls out the
    # optional source argument.  A same-root event is harmlessly deduplicated.
    return simpletree#ExternalSetRoot(path)
  endtry
enddef

def WorkspaceSwitchOptions(local_root: string): dict<any>
  var options = copy(get(s_remote, 'options', {}))
  options.open_tree = SimpleTreeVisible() || !empty(s_tree)

  # A profile local_root describes the old remote root.  Carrying it to a new
  # SSHFS or Docker workspace would project the wrong directory.  Explicit
  # local maps are the exception: a SimpleTree path gives us the exact new
  # local half of that mapping.
  if get(s_remote, 'workspace_mode', '') ==# 'local-map' && !empty(local_root)
    options.local_root = local_root
  elseif has_key(options, 'local_root')
    remove(options, 'local_root')
  endif
  return options
enddef

def SwitchWorkspaceRoot(generation: number, root: string, local_root: string,
    source: string)
  s_workspace_switch_timer = 0
  if !IsCurrent(generation) || !IsReady() || root ==# s_remote.root
    return
  endif
  var kind = s_remote.kind
  var target = s_remote.target
  var options = WorkspaceSwitchOptions(local_root)
  echomsg printf('[SimpleRemote] workspace root -> %s (%s)', root, source)
  Connect(kind, target, root, options)
enddef

def QueueWorkspaceRoot(path: string, local_root: string = '',
    source: string = 'tree'): bool
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return false
  endif
  var target = NormalizeTreeRoot(path)
  if empty(target)
    Error('[SimpleRemote] workspace root must be an absolute remote path')
    return false
  endif
  if target ==# s_remote.root
    # This is usually our own tree projection arriving through an older
    # SimpleTree that does not publish a source.  Keep detached/reveal views
    # coherent without reconnecting to the workspace we already have.
    return SetRemoteTreeRoot(target, false)
  endif
  if s_workspace_switch_timer > 0
    timer_stop(s_workspace_switch_timer)
  endif
  var generation = s_remote.generation
  s_workspace_switch_timer = timer_start(0,
    (_) => SwitchWorkspaceRoot(generation, target, local_root, source))
  return true
enddef

def RemoteTreeLocalPath(remote_path: string): string
  var base = substitute(get(s_remote, 'local_root', ''), '[\\/]\+$', '', '')
  var suffix = strpart(remote_path, len(s_remote.root))
  return s_remote.root ==# '/'
    ? base .. '/' .. substitute(suffix, '^/', '', '')
    : base .. suffix
enddef

def SetRemoteTreeRoot(path: string, sync_view: bool = true): bool
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return false
  endif
  var target = NormalizeTreeRoot(path)
  if empty(target)
    Error('[SimpleRemote] tree root must be an absolute remote path')
    return false
  endif
  if sync_view && get(g:, 'simpleremote_sync_tree_root', 1)
    return QueueWorkspaceRoot(target, '', 'remote-tree')
  endif
  s_remote.tree_root = target
  g:simpleremote_workspace = WorkspaceSnapshot()
  Emit('SimpleRemoteTreeRootChanged', {
    root: target,
    workspace: s_remote.root,
    mode: get(s_remote, 'workspace_mode', 'virtual'),
  })
  var local_root = get(s_remote, 'local_root', '')
  if sync_view && !empty(local_root) && UnderRoot(target, s_remote.root)
        && SimpleTreeVisible() && exists('*simpletree#ExternalSetRoot') == 1
    var local_target = RemoteTreeLocalPath(target)
    if !SetSimpleTreeRoot(local_target)
      Error('[SimpleRemote] local tree root is unavailable: ' .. local_target)
      return false
    endif
  elseif sync_view && !empty(local_root) && UnderRoot(target, s_remote.root)
    CloseRemoteTree()
    var local_target = RemoteTreeLocalPath(target)
    if exists(':SimpleTree') == 2
      execute 'SimpleTree ' .. fnameescape(local_target)
    elseif exists(':Explore') == 2
      execute 'Explore ' .. fnameescape(local_target)
    endif
  elseif sync_view && !empty(local_root)
    if SimpleTreeVisible() && exists(':SimpleTreeClose') == 2
      silent! execute 'SimpleTreeClose'
    endif
    OpenRemoteTree(target)
  elseif !empty(s_tree)
    LoadRemoteTree(target)
  endif
  return true
enddef

def RemoteTreeRootHere()
  if get(s_tree, 'root_locked', false)
    echomsg '[SimpleRemote] root is locked; press L to unlock'
    return
  endif
  var node = CurrentRemoteTreeNode()
  if empty(node)
    return
  endif
  var target = get(node, 'type', '') ==# 'd'
    ? node.path : RemoteParent(node.path)
  SetRemoteTreeRoot(target)
enddef

def RemoteTreeRootUp()
  if get(s_tree, 'root_locked', false)
    echomsg '[SimpleRemote] root is locked; press L to unlock'
    return
  endif
  var current = get(s_tree, 'root', get(s_remote, 'tree_root', s_remote.root))
  if current ==# '/'
    echomsg '[SimpleRemote] already at remote filesystem root'
    return
  endif
  SetRemoteTreeRoot(RemoteParent(current))
enddef

def RemoteTreeRootPrompt()
  if get(s_tree, 'root_locked', false)
    echomsg '[SimpleRemote] root is locked; press L to unlock'
    return
  endif
  var current = get(s_tree, 'root', get(s_remote, 'tree_root', s_remote.root))
  var target = input('Remote tree root: ', current)
  if !empty(target)
    SetRemoteTreeRoot(target)
  endif
enddef

def RemoteTreeRootReset()
  if get(s_tree, 'root_locked', false)
    echomsg '[SimpleRemote] root is locked; press L to unlock'
    return
  endif
  SetRemoteTreeRoot(s_remote.root)
enddef

def RemoteTreeRootCurrent()
  if get(s_tree, 'root_locked', false)
    echomsg '[SimpleRemote] root is locked; press L to unlock'
    return
  endif
  var source = get(s_tree, 'source_win', 0)
  var windows = source > 0 ? getwininfo(source) : []
  if empty(windows)
    echomsg '[SimpleRemote] no active remote file window'
    return
  endif
  var path = get(getbufvar(windows[0].bufnr, 'vimrc_remote', {}), 'path', '')
  if empty(path)
    path = getbufvar(windows[0].bufnr, 'simpleremote_path', '')
  endif
  if empty(path)
    echomsg '[SimpleRemote] active window is not a remote file'
    return
  endif
  SetRemoteTreeRoot(RemoteParent(path))
enddef

def RemoteTreeToggleRootLock()
  s_tree.root_locked = !get(s_tree, 'root_locked', false)
  RenderRemoteTree(s_tree.buf)
  echomsg '[SimpleRemote] root lock: ' .. (s_tree.root_locked ? 'ON' : 'OFF')
enddef

var s_tree_help_popup: number = 0

def RemoteTreeHelpClosed(id: number, _result: number)
  if s_tree_help_popup == id
    s_tree_help_popup = 0
  endif
enddef

def RemoteTreeHelpFilter(id: number, key: string): number
  if key ==# '?' || key ==# 'q' || key ==# "\<Esc>"
    try
      popup_close(id)
    catch
    endtry
    s_tree_help_popup = 0
    return 1
  endif
  return 1
enddef

def RemoteTreeHelp()
  if s_tree_help_popup != 0 && exists('*popup_close') == 1
    try
      popup_close(s_tree_help_popup)
    catch
    endtry
    s_tree_help_popup = 0
    return
  endif
  var lines = [
    'NAVIGATE',
    '  <CR> / o / l / Right   open or expand',
    '  h / Left / <BS>        collapse / parent node',
    '  S / V / t              split / vsplit / tab',
    '  C-x / C-v / C-t        split / vsplit / tab',
    '  P                      preview file',
    '  f                      reveal active remote file',
    '',
    'TREE ROOT',
    '  e            selected directory becomes tree root',
    '  U            tree root goes up (up to remote /)',
    '  C            enter any absolute remote tree root',
    '  .            restore connected workspace root',
    '  d            active remote file directory becomes root',
    '  L            toggle root lock',
    '',
    'FILES',
    '  c / x / p    copy / cut / paste remote nodes',
    '  a / n        create file in target directory',
    '  A / N        create folder in target directory',
    '  r / D        rename / delete remote nodes',
    '  gd           download file/directory into local SimpleTree',
    '  gu           upload a local file/directory here',
    '  gy           copy remote file contents',
    '  y / Y        copy file name / absolute remote path',
    '',
    'MARKS AND BOOKMARKS',
    '  Space        toggle mark (Visual: mark range)',
    '  gm / gM      mark siblings / clear marks',
    "  m / '        toggle / list persistent bookmark",
    '  ]b / [b      next / previous visible bookmark',
    '',
    'GENERAL',
    '  R            refresh tree',
    '  H            toggle hidden files',
    '  I            toggle gitignore filtering',
    '  s / gs       cycle / reverse sort',
    '  F            filter loaded nodes (empty clears)',
    '  z            collapse all directories',
    '  /            find a visible node',
    '  ]f / [f      next / previous find match',
    '  q / <Esc>    close this help',
    '  ?            show or close this help',
  ]
  if exists('*popup_create') == 1
    s_tree_help_popup = popup_create(lines, {
      title: ' SimpleRemote tree keys ',
      pos: 'center',
      padding: [0, 1, 0, 1],
      border: [1, 1, 1, 1],
      borderchars: ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
      minwidth: min([62, &columns - 4]),
      maxheight: max([8, &lines - 4]),
      close: 'click',
      mapping: 0,
      filter: RemoteTreeHelpFilter,
      callback: RemoteTreeHelpClosed,
      zindex: 300,
    })
    return
  endif
  for line in lines
    echomsg line
  endfor
enddef

# Names for the multi-key tree mappings in SimpleWhichKey's panel; the tree
# buffer is wiped on close, so the buffer-scoped registration dies with it.
def DescribeTreeKeys()
  if exists('*simplewhichkey#Describe') != 1
    return
  endif
  try
    simplewhichkey#Describe({
      gs: 'reverse sort', gm: 'mark siblings', gM: 'clear marks',
      gy: 'copy file contents', gd: 'download to local tree',
      gu: 'upload local file here',
      ']f': 'next find match', '[f': 'previous find match',
      ']b': 'next bookmark', '[b': 'previous bookmark',
    }, 'n', true)
  catch
  endtry
enddef

def RemoteTreeToggleHidden()
  g:simpleremote_tree_show_hidden = get(g:, 'simpleremote_tree_show_hidden', 1)
    ? 0 : 1
  RefreshRemoteTree()
  echomsg '[SimpleRemote] hidden files: '
    .. (g:simpleremote_tree_show_hidden ? 'shown' : 'hidden')
enddef

def RemoteTreeToggleGitIgnore()
  s_tree.git_ignore = !get(s_tree, 'git_ignore', true)
  if s_tree.git_ignore && empty(get(s_tree, 'git_ignored', {}))
    LoadTreeGit()
  else
    RenderRemoteTree(s_tree.buf)
  endif
  echomsg '[SimpleRemote] gitignore filter: '
    .. (s_tree.git_ignore ? 'ON' : 'OFF')
enddef

def RemoteTreeFilter()
  var query = input('Filter loaded remote nodes: ',
    get(s_tree, 'filter_query', ''))
  s_tree.filter_query = query
  RenderRemoteTree(s_tree.buf)
  echomsg empty(query) ? '[SimpleRemote] filter cleared'
    : '[SimpleRemote] filter: ' .. query
enddef

def RemoteTreeSortCycle()
  var current = TreeSortMode()
  var index = index(TREE_SORT_MODES, current)
  s_tree.sort = TREE_SORT_MODES[(index + 1) % len(TREE_SORT_MODES)]
  g:simpleremote_tree_sort = s_tree.sort
  if index(['mtime', 'size'], s_tree.sort) >= 0
    ReloadRemoteTree(true)
  else
    for path in keys(s_tree.cache)
      sort(s_tree.cache[path], TreeNodeCompare)
    endfor
    RenderRemoteTree(s_tree.buf)
  endif
  echomsg '[SimpleRemote] sort: ' .. s_tree.sort
enddef

def RemoteTreeSortReverse()
  s_tree.sort_reverse = !get(s_tree, 'sort_reverse', false)
  g:simpleremote_tree_sort_reverse = s_tree.sort_reverse ? 1 : 0
  for path in keys(s_tree.cache)
    sort(s_tree.cache[path], TreeNodeCompare)
  endfor
  RenderRemoteTree(s_tree.buf)
  echomsg '[SimpleRemote] sort reverse: '
    .. (s_tree.sort_reverse ? 'ON' : 'OFF')
enddef

def RemoteTreeCollapseAll()
  if empty(s_tree)
    return
  endif
  # Brackets because the key is computed: Vim9 reads {s_tree.root: true} as the
  # literal key `s_tree` followed by `.root`, and refuses the whole function
  # with E720 — which is why `z` in the tree has never collapsed anything.
  s_tree.expanded = {[s_tree.root]: true}
  s_tree.reveal = s_tree.root
  RenderRemoteTree(s_tree.buf)
  echomsg '[SimpleRemote] collapsed all directories'
enddef

def RemoteTreeFind(ask: bool, direction: number = 1)
  if empty(s_tree) || !bufexists(get(s_tree, 'buf', -1))
    return
  endif
  var query = get(s_tree, 'find_query', '')
  if ask
    query = input('Find remote node: ', query)
    if empty(query)
      return
    endif
    s_tree.find_query = query
  elseif empty(query)
    echomsg '[SimpleRemote] no active tree find; press / first'
    return
  endif
  var nodes = getbufvar(s_tree.buf, 'simpleremote_tree_nodes', [])
  if empty(nodes)
    return
  endif
  var current = bufwinid(s_tree.buf) > 0
    ? getcurpos(bufwinid(s_tree.buf))[1] - 1 : 0
  var needle = tolower(query)
  var total = len(nodes)
  for step in range(1, total)
    var index = (current + direction * step + total * 2) % total
    var node = get(nodes, index, {})
    var path = get(node, 'path', '')
    if !empty(path) && (stridx(tolower(fnamemodify(path, ':t')), needle) >= 0
          || stridx(tolower(path), needle) >= 0)
      var winid = bufwinid(s_tree.buf)
      if winid > 0
        win_execute(winid, printf('cursor(%d, 1)', index + 1))
      endif
      return
    endif
  endfor
  echomsg '[SimpleRemote] no visible match: ' .. query
enddef

def RemoteTreeRevealActive()
  var source = get(s_tree, 'source_win', 0)
  var windows = source > 0 ? getwininfo(source) : []
  if empty(windows)
    echomsg '[SimpleRemote] no active remote file window'
    return
  endif
  var buffer = windows[0].bufnr
  var info = getbufvar(buffer, 'vimrc_remote', {})
  var path = type(info) == v:t_dict ? get(info, 'path', '') : ''
  if empty(path)
    path = getbufvar(buffer, 'simpleremote_path', '')
  endif
  if empty(path)
    echomsg '[SimpleRemote] active window is not a remote file'
    return
  endif
  var parent = RemoteParent(path)
  # Reveal is view-only.  Explicit root navigation (e/U/C) changes the real
  # workspace, but locating the active file must not restart it.
  SetRemoteTreeRoot(parent, false)
  OpenRemoteTree(parent, path)
enddef

def ReloadRemoteTree(force: bool = false)
  if empty(s_tree)
    return
  endif
  var root = s_tree.root
  s_tree.epoch += 1
  s_tree.cache = {}
  s_tree.loading = {}
  s_tree.errors = {}
  s_tree.git = {}
  s_tree.git_ignored = {}
  if force
    s_tree.metadata_supported = -1
  endif
  s_tree.expanded[root] = true
  for path in keys(s_tree.expanded)
    LoadTreeDirectory(path, true)
  endfor
  LoadTreeGit()
enddef

def RefreshRemoteTree()
  ReloadRemoteTree()
enddef

def CurrentRemoteTreeNode(): dict<any>
  if &filetype !=# 'simpleremotetree'
    return {}
  endif
  var nodes = get(b:, 'simpleremote_tree_nodes', [])
  var index = line('.') - 1
  return index >= 0 && index < len(nodes) ? get(nodes, index, {}) : {}
enddef

def RemoteTreeNodeAtLine(lnum: number): dict<any>
  var nodes = getbufvar(get(s_tree, 'buf', -1), 'simpleremote_tree_nodes', [])
  var index = lnum - 1
  return index >= 0 && index < len(nodes) ? get(nodes, index, {}) : {}
enddef

def RemoteTreeTargetDirectory(): string
  var node = CurrentRemoteTreeNode()
  if empty(node)
    return get(s_tree, 'root', s_remote.root)
  endif
  return get(node, 'type', '') ==# 'd' ? node.path : RemoteParent(node.path)
enddef

def ValidRemoteRelative(path: string): bool
  if empty(path) || path =~# '^/' || path =~# "[\r\n\t]"
    return false
  endif
  for part in split(path, '/', 1)
    if empty(part) || part ==# '.' || part ==# '..'
      return false
    endif
  endfor
  return true
enddef

def RemoteTreeMutationFinished(generation: number, label: string,
    focus: string, open_after: bool, ok: bool, body: string)
  if !IsCurrent(generation)
    return
  endif
  if !ok
    Error('[SimpleRemote] ' .. label .. ' failed: ' .. trim(body))
    return
  endif
  var tree_open = !empty(s_tree) && bufexists(get(s_tree, 'buf', -1))
  if tree_open
    if !empty(focus)
      s_tree.reveal = focus
    endif
    ReloadRemoteTree()
  endif
  echomsg '[SimpleRemote] ' .. label .. ': ' .. focus
  if open_after
    FocusEditWindow()
    OpenRemote(focus)
  endif
enddef

def RemoteTreeNew(directory: bool)
  var parent = RemoteTreeTargetDirectory()
  var relative = input(directory ? 'New remote folder: ' : 'New remote file: ')
  if empty(relative)
    return
  endif
  if !ValidRemoteRelative(relative)
    Error('[SimpleRemote] use a relative path without . or .. components')
    return
  endif
  var target = JoinRemotePath(parent, relative)
  var quoted = shellescape(target)
  var target_parent = shellescape(RemoteParent(target))
  var command = 'if [ -e ' .. quoted .. ' ] || [ -L ' .. quoted
    .. ' ]; then printf "already exists: %s\\n" ' .. quoted
    .. ' >&2; exit 47; fi; mkdir -p ' .. target_parent
    .. (directory ? ' && mkdir ' .. quoted : ' && : > ' .. quoted)
  var generation = s_remote.generation
  Send('exec', {command: command}, (ok, body) => {
    if ok && IsCurrent(generation)
      AnnounceFilesChanged([{path: target, type: 'created'}])
    endif
    RemoteTreeMutationFinished(generation,
      directory ? 'created folder' : 'created file', target, !directory,
      ok, body)
  })
enddef

def RewriteRemotePath(path: string, source: string, target: string): string
  return path ==# source ? target
    : UnderRoot(path, source) ? target .. strpart(path, len(source)) : path
enddef

# Give a remote buffer the name its b:vimrc_remote.uri says it has.  `:file`
# needs the buffer to be current, so a visible buffer is renamed through its
# window and a hidden one waits for its next BufEnter (see
# g:VimrcRemoteActivateBuffer).  The unlisted buffer Vim keeps for the old
# name is wiped so it cannot be picked up as a stale remote:// entry.
# Find the buffer already holding a remote path, whatever it is currently
# named: a buffer renamed while hidden keeps its old name until it is entered,
# and looking it up by name alone would make a second buffer for the same file
# — two buffers whose writes overwrite each other.
def RemoteBufferFor(remote_path: string): number
  var direct = bufnr('^remote://' .. remote_path .. '$')
  if direct > 0
    return direct
  endif
  for info in getbufinfo()
    var remote = getbufvar(info.bufnr, 'vimrc_remote', {})
    if type(remote) == v:t_dict && get(remote, 'path', '') ==# remote_path
      return info.bufnr
    endif
  endfor
  return -1
enddef

def SyncRemoteBufferName(buf: number)
  var info = getbufvar(buf, 'vimrc_remote', {})
  var uri = type(info) == v:t_dict ? get(info, 'uri', '') : ''
  if empty(uri) || bufname(buf) ==# uri
    return
  endif
  # Another buffer may already carry the name this one is taking — a leftover
  # of an earlier rename.  Vim refuses :file when the name is taken, and the
  # error would be swallowed, so clear the way or say why it cannot be.
  for taken in getbufinfo()
    if taken.bufnr == buf || taken.name !=# uri
      continue
    endif
    if taken.listed || get(taken, 'changed', 0)
      Error('[SimpleRemote] another buffer already holds ' .. uri)
      return
    endif
    execute 'silent! bwipeout ' .. taken.bufnr
  endfor
  var old_name = bufname(buf)
  var winid = bufwinid(buf)
  if buf == bufnr()
    execute 'silent! keepalt file ' .. fnameescape(uri)
  elseif winid > 0
    win_execute(winid, 'silent! keepalt file ' .. fnameescape(uri))
  else
    return
  endif
  # Exact-name lookup: bufnr() would treat the old name as a file pattern.
  for other in getbufinfo()
    if other.bufnr != buf && other.name ==# old_name && !other.listed
          && !get(other, 'changed', 0)
      execute 'silent! bwipeout ' .. other.bufnr
    endif
  endfor
enddef

def RetargetRemoteBuffers(source: string, target: string)
  for info in getbufinfo()
    var remote = getbufvar(info.bufnr, 'vimrc_remote', {})
    var path = type(remote) == v:t_dict ? get(remote, 'path', '') : ''
    if get(remote, 'generation', -1) != s_remote.generation
          || (path !=# source && !UnderRoot(path, source))
      continue
    endif
    var updated = RewriteRemotePath(path, source, target)
    remote.path = updated
    remote.uri = 'remote://' .. updated
    setbufvar(info.bufnr, 'vimrc_remote', remote)
    setbufvar(info.bufnr, 'simpleremote_path', updated)
    SyncRemoteBufferName(info.bufnr)
  endfor
enddef

# Announce filesystem changes made outside buffer writes (tree mutations,
# uploads, API writes) so language servers and other watchers can follow.
# Each change is {path, type} with type 'created', 'changed' or 'deleted'.
def AnnounceFilesChanged(changes: list<dict<any>>)
  if empty(changes) || empty(s_remote)
    return
  endif
  Emit('SimpleRemoteFilesChanged', {
    changes: changes,
    workspace: copy(get(g:, 'simpleremote_workspace', {})),
  })
enddef

def RewriteRemoteTreeMaps(source: string, target: string)
  LoadTreeBookmarks()
  var marked: dict<any> = {}
  for [path, kind] in items(get(s_tree, 'marked', {}))
    marked[RewriteRemotePath(path, source, target)] = kind
  endfor
  s_tree.marked = marked
  var expanded: dict<bool> = {}
  for path in keys(get(s_tree, 'expanded', {}))
    expanded[RewriteRemotePath(path, source, target)] = true
  endfor
  s_tree.expanded = expanded
  for [key, node] in items(copy(s_tree_bookmarks))
    if get(node, 'kind', '') ==# s_remote.kind
          && get(node, 'target', '') ==# s_remote.target
          && (node.path ==# source || UnderRoot(node.path, source))
      remove(s_tree_bookmarks, key)
      node.path = RewriteRemotePath(node.path, source, target)
      node.name = fnamemodify(node.path, ':t')
      s_tree_bookmarks[TreeBookmarkKey(node.path)] = node
    endif
  endfor
  SaveTreeBookmarks()
enddef

def RemoteTreeRename()
  var node = CurrentRemoteTreeNode()
  if empty(node)
    return
  endif
  if node.path ==# s_tree.root
    Error('[SimpleRemote] refusing to rename the tree root')
    return
  endif
  var name = input('Rename remote node: ', node.name)
  if empty(name) || name ==# node.name
    return
  endif
  if !ValidRemoteRelative(name) || name =~# '/'
    Error('[SimpleRemote] the new name must be one path component')
    return
  endif
  var source = node.path
  var target = JoinRemotePath(RemoteParent(source), name)
  var quoted_target = shellescape(target)
  var command = 'if [ -e ' .. quoted_target .. ' ] || [ -L '
    .. quoted_target .. ' ]; then printf "already exists: %s\\n" '
    .. quoted_target .. ' >&2; exit 47; fi; mv ' .. shellescape(source)
    .. ' ' .. quoted_target
  var generation = s_remote.generation
  Send('exec', {command: command}, (ok, body) => {
    if ok && IsCurrent(generation)
      RetargetRemoteBuffers(source, target)
      RewriteRemoteTreeMaps(source, target)
      AnnounceFilesChanged([{path: source, type: 'deleted'},
        {path: target, type: 'created'}])
    endif
    RemoteTreeMutationFinished(generation, 'renamed', target, false, ok, body)
  })
enddef

def RemoteTreeActionNodes(): list<dict<any>>
  var result: list<dict<any>> = []
  var marked = get(s_tree, 'marked', {})
  if !empty(marked)
    for path in sort(keys(marked))
      var covered = false
      for parent in result
        if parent.type ==# 'd' && UnderRoot(path, parent.path)
          covered = true
          break
        endif
      endfor
      if covered
        continue
      endif
      add(result, {path: path, name: fnamemodify(path, ':t'), type: marked[path]})
    endfor
    return result
  endif
  var node = CurrentRemoteTreeNode()
  return empty(node) ? result : [node]
enddef

def RemoteTreeMarkToggle()
  var node = CurrentRemoteTreeNode()
  if empty(node)
    return
  endif
  if has_key(s_tree.marked, node.path)
    remove(s_tree.marked, node.path)
  else
    s_tree.marked[node.path] = node.type
  endif
  RenderRemoteTree(s_tree.buf)
enddef

def RemoteTreeMarkRange(first: number, last: number)
  for lnum in range(min([first, last]), max([first, last]))
    var node = RemoteTreeNodeAtLine(lnum)
    if !empty(node)
      s_tree.marked[node.path] = node.type
    endif
  endfor
  RenderRemoteTree(s_tree.buf)
enddef

def RemoteTreeMarkSiblings()
  var current = CurrentRemoteTreeNode()
  if empty(current)
    return
  endif
  for node in getbufvar(s_tree.buf, 'simpleremote_tree_nodes', [])
    if !empty(node) && get(node, 'parent', '') ==# get(current, 'parent', '')
      s_tree.marked[node.path] = node.type
    endif
  endfor
  RenderRemoteTree(s_tree.buf)
enddef

def RemoteTreeMarkClear()
  s_tree.marked = {}
  RenderRemoteTree(s_tree.buf)
enddef

def RemoteTreeClipboard(mode: string)
  var nodes = RemoteTreeActionNodes()
  if empty(nodes)
    return
  endif
  if mode ==# 'cut'
    for node in nodes
      if node.path ==# s_tree.root
        Error('[SimpleRemote] refusing to cut the tree root')
        return
      endif
    endfor
  endif
  var clipboard_items: list<dict<any>> = []
  for node in nodes
    add(clipboard_items, {path: node.path, type: node.type})
  endfor
  s_tree_clipboard = {
    mode: mode,
    kind: s_remote.kind,
    target: s_remote.target,
    items: clipboard_items,
  }
  echomsg printf('[SimpleRemote] %s %d remote node%s',
    mode ==# 'cut' ? 'cut' : 'copied', len(nodes), len(nodes) == 1 ? '' : 's')
enddef

def RemoteTreePaste()
  if empty(s_tree_clipboard)
    echomsg '[SimpleRemote] remote clipboard is empty'
    return
  endif
  if get(s_tree_clipboard, 'kind', '') !=# s_remote.kind
        || get(s_tree_clipboard, 'target', '') !=# s_remote.target
    Error('[SimpleRemote] remote clipboard belongs to another target')
    return
  endif
  var destination = RemoteTreeTargetDirectory()
  var mode = get(s_tree_clipboard, 'mode', 'copy')
  var checks: list<string> = []
  var operations: list<string> = []
  for item in get(s_tree_clipboard, 'items', [])
    var source = item.path
    var target = JoinRemotePath(destination, fnamemodify(source, ':t'))
    if get(item, 'type', '') ==# 'd' && UnderRoot(target, source)
      Error('[SimpleRemote] cannot paste a directory into itself: ' .. source)
      return
    endif
    var quoted_target = shellescape(target)
    add(checks, 'if [ -e ' .. quoted_target .. ' ] || [ -L '
      .. quoted_target .. ' ]; then printf "already exists: %s\\n" '
      .. quoted_target .. ' >&2; exit 47; fi')
    add(operations, (mode ==# 'cut' ? 'mv ' : 'cp -RP ')
      .. shellescape(source) .. ' ' .. quoted_target)
  endfor
  var generation = s_remote.generation
  Send('exec', {command: join(['set -e'] + checks + operations, '; ')}, (ok, body) => {
    if ok && IsCurrent(generation)
      var changes: list<dict<any>> = []
      for item in get(s_tree_clipboard, 'items', [])
        var moved = JoinRemotePath(destination, fnamemodify(item.path, ':t'))
        if mode ==# 'cut'
          RetargetRemoteBuffers(item.path, moved)
          RewriteRemoteTreeMaps(item.path, moved)
          add(changes, {path: item.path, type: 'deleted'})
        endif
        add(changes, {path: moved, type: 'created'})
      endfor
      AnnounceFilesChanged(changes)
      if mode ==# 'cut'
        s_tree_clipboard = {}
        s_tree.marked = {}
      endif
    endif
    RemoteTreeMutationFinished(generation,
      mode ==# 'cut' ? 'moved' : 'pasted', destination, false, ok, body)
  })
enddef

def ModifiedRemoteBufferUnder(root: string): string
  for info in getbufinfo()
    if !get(info, 'changed', 0)
      continue
    endif
    var remote = getbufvar(info.bufnr, 'vimrc_remote', {})
    var path = type(remote) == v:t_dict ? get(remote, 'path', '') : ''
    if get(remote, 'generation', -1) == s_remote.generation
          && (path ==# root || UnderRoot(path, root))
      return path
    endif
  endfor
  return ''
enddef

def RemoteTreeDelete()
  var nodes = RemoteTreeActionNodes()
  if empty(nodes)
    return
  endif
  for node in nodes
    if node.path ==# s_tree.root
      Error('[SimpleRemote] refusing to delete the tree root')
      return
    endif
    var modified = ModifiedRemoteBufferUnder(node.path)
    if !empty(modified)
      Error('[SimpleRemote] refusing to delete a modified remote buffer: ' .. modified)
      return
    endif
  endfor
  var label = len(nodes) == 1 ? nodes[0].path : printf('%d marked nodes', len(nodes))
  if get(g:, 'simpleremote_confirm_delete', 1)
        && confirm('Delete remote ' .. label .. '?', "&Delete\n&Cancel", 2) != 1
    return
  endif
  var commands = ['set -e']
  for node in nodes
    add(commands, 'rm -rf ' .. shellescape(node.path))
  endfor
  var generation = s_remote.generation
  Send('exec', {command: join(commands, '; ')}, (ok, body) => {
    if ok && IsCurrent(generation)
      AnnounceFilesChanged(mapnew(nodes,
        (_, node) => ({path: node.path, type: 'deleted'})))
      s_tree.marked = {}
      LoadTreeBookmarks()
      for node in nodes
        for path in keys(copy(s_tree.expanded))
          if path ==# node.path || UnderRoot(path, node.path)
            remove(s_tree.expanded, path)
          endif
        endfor
        for [key, bookmark] in items(copy(s_tree_bookmarks))
          if bookmark.path ==# node.path || UnderRoot(bookmark.path, node.path)
            remove(s_tree_bookmarks, key)
          endif
        endfor
      endfor
      SaveTreeBookmarks()
    endif
    RemoteTreeMutationFinished(generation, 'deleted', label, false, ok, body)
  })
enddef

def TreeBookmarkKey(path: string): string
  return s_remote.kind .. "\t" .. s_remote.target .. "\t" .. path
enddef

def TreeBookmarksFile(): string
  var configured = expand(get(g:, 'simpleremote_tree_bookmarks_file', ''))
  return !empty(configured) ? configured
    : ProjectionStateDir() .. '/tree-bookmarks.json'
enddef

def LoadTreeBookmarks()
  if s_tree_bookmarks_loaded
    return
  endif
  s_tree_bookmarks_loaded = true
  var file = TreeBookmarksFile()
  if !filereadable(file)
    return
  endif
  try
    var decoded = json_decode(join(readfile(file), "\n"))
    if type(decoded) == v:t_dict
      s_tree_bookmarks = decoded
    endif
  catch
    Error('[SimpleRemote] invalid tree bookmarks: ' .. v:exception)
  endtry
enddef

def SaveTreeBookmarks()
  var file = TreeBookmarksFile()
  if !EnsurePrivateDir(fnamemodify(file, ':h'))
    Error('[SimpleRemote] cannot create tree bookmark directory')
    return
  endif
  var temporary = file .. '.tmp.' .. getpid()
  try
    writefile([json_encode(s_tree_bookmarks)], temporary)
    if rename(temporary, file) != 0
      delete(temporary)
      Error('[SimpleRemote] cannot save tree bookmarks')
    endif
  catch
    delete(temporary)
    Error('[SimpleRemote] cannot save tree bookmarks: ' .. v:exception)
  endtry
enddef

def TreeBookmarked(path: string): bool
  LoadTreeBookmarks()
  return has_key(s_tree_bookmarks, TreeBookmarkKey(path))
enddef

def RemoteTreeBookmarkToggle()
  LoadTreeBookmarks()
  var node = CurrentRemoteTreeNode()
  if empty(node)
    return
  endif
  var key = TreeBookmarkKey(node.path)
  if has_key(s_tree_bookmarks, key)
    remove(s_tree_bookmarks, key)
  else
    s_tree_bookmarks[key] = {
      kind: s_remote.kind,
      target: s_remote.target,
      path: node.path,
      name: node.name,
      type: node.type,
    }
  endif
  SaveTreeBookmarks()
  RenderRemoteTree(s_tree.buf)
enddef

def RemoteTreeBookmarkNodes(): list<dict<any>>
  LoadTreeBookmarks()
  var result: list<dict<any>> = []
  for node in values(s_tree_bookmarks)
    if node.kind ==# s_remote.kind && node.target ==# s_remote.target
      add(result, node)
    endif
  endfor
  sort(result, (a, b) => TreeTextCompare(a.path, b.path))
  return result
enddef

def OpenRemoteTreeBookmark(nodes: list<dict<any>>, result: number)
  if result <= 0 || result > len(nodes)
    return
  endif
  var node = nodes[result - 1]
  if node.type ==# 'd'
    SetRemoteTreeRoot(RemoteParent(node.path), false)
    OpenRemoteTree(RemoteParent(node.path), node.path)
  else
    OpenRemote(node.path)
  endif
enddef

def RemoteTreeBookmarkList()
  var nodes = RemoteTreeBookmarkNodes()
  if empty(nodes)
    echomsg '[SimpleRemote] no remote bookmarks for this target'
    return
  endif
  var labels = mapnew(nodes, (_, node) =>
    (node.type ==# 'd' ? '[dir] ' : '      ') .. node.path)
  if exists('*popup_menu') == 1
    popup_menu(labels, {
      title: ' SimpleRemote bookmarks ',
      callback: (_id, result) => OpenRemoteTreeBookmark(nodes, result),
      maxheight: min([18, &lines - 4]),
      minwidth: min([72, &columns - 4]),
    })
  else
    OpenRemoteTreeBookmark(nodes, inputlist(['Remote bookmarks:'] + labels))
  endif
enddef

def RemoteTreeBookmarkCycle(direction: number)
  var nodes = getbufvar(s_tree.buf, 'simpleremote_tree_nodes', [])
  var current = line('.') - 1
  var total = len(nodes)
  for step in range(1, total)
    var index = (current + direction * step + total * 2) % total
    var node = get(nodes, index, {})
    if !empty(node) && TreeBookmarked(node.path)
      cursor(index + 1, 1)
      return
    endif
  endfor
  echomsg '[SimpleRemote] no other visible bookmark'
enddef

def CopyText(text: string): bool
  if exists('*simpleclipboard#CopyText') == 1
    try
      return simpleclipboard#CopyText(text)
    catch
      Error('[SimpleRemote] SimpleClipboard failed: ' .. v:exception)
    endtry
  endif
  setreg('"', text)
  if has('clipboard')
    try
      setreg('+', text)
      return true
    catch
    endtry
  endif
  return false
enddef

def YankRemoteTreeValue(absolute: bool)
  var node = CurrentRemoteTreeNode()
  if empty(node) || empty(get(node, 'path', ''))
    return
  endif
  var value = absolute ? node.path : fnamemodify(node.path, ':t')
  var copied = CopyText(value)
  echomsg printf('[SimpleRemote] yanked %s%s', value,
    copied ? '' : ' (unnamed register only)')
enddef

def OnRemoteContentRead(path: string, ok: bool, body: string)
  if !ok
    Error('[SimpleRemote] cannot copy file contents: ' .. body)
    return
  endif
  var content = body
  var configured = get(g:, 'simpleremote_clipboard_max_bytes', 1024 * 1024)
  var limit = type(configured) == v:t_number && configured >= 0
    ? configured : 1024 * 1024
  if limit > 0 && strlen(content) > limit
    Error(printf('[SimpleRemote] file is %d bytes; clipboard limit is %d',
      strlen(content), limit))
    return
  endif
  var copied = CopyText(content)
  echomsg printf('[SimpleRemote] copied contents of %s%s', path,
    copied ? '' : ' (unnamed register only)')
enddef

def CopyRemoteTreeContents()
  var node = CurrentRemoteTreeNode()
  if empty(node) || empty(get(node, 'path', ''))
    return
  endif
  if get(node, 'type', '') ==# 'd'
    Error('[SimpleRemote] directory contents cannot be copied to the text clipboard')
    return
  endif
  Send('read', {path: node.path},
    (ok, body) => OnRemoteContentRead(node.path, ok, body))
  echomsg '[SimpleRemote] reading ' .. node.path
enddef

def LocalCopyDirectory(): string
  var configured = expand(get(g:, 'simpleremote_copy_destination', ''))
  if !empty(configured) && isdirectory(configured)
    return fnamemodify(configured, ':p')
  endif
  if exists('*simpletree#ExternalDropDirectory') == 1
    try
      var directory = simpletree#ExternalDropDirectory()
      if !empty(directory) && isdirectory(directory)
        return fnamemodify(directory, ':p')
      endif
    catch
      Error('[SimpleRemote] SimpleTree destination failed: ' .. v:exception)
    endtry
  endif
  return ''
enddef

# ---------------------------------------------------------------------------
# Cross-boundary transfers.  One engine serves the tree keys (gd/gu), the
# commands (:SimpleRemoteDownload/:SimpleRemoteUpload) and the public API that
# sibling plugins call.  With the Rust runtime present, files and directories
# stream through `simpleremote-daemon download|upload`, which stages beside
# the destination and activates it atomically; without it, scp/docker cp do
# the same job with their own semantics.
# ---------------------------------------------------------------------------

def RuntimeHandlesTransfer(direction: string, options: dict<any>): bool
  var recursive = !!get(options, 'recursive', false)
  return !empty(DaemonPath())
    && (direction ==# 'download' || RuntimeSupports('upload'))
    && (!recursive || RuntimeSupports('recursive_transfer'))
enddef

def TransferCommand(direction: string, remote: string, local: string,
    options: dict<any>): list<string>
  var force = !!get(options, 'force', false)
  var recursive = !!get(options, 'recursive', false)
  var daemon = DaemonPath()
  if RuntimeHandlesTransfer(direction, options)
    var command = [daemon, direction, '--kind', s_remote.kind,
      '--target', s_remote.target, '--root', s_remote.root,
      '--remote', remote, '--local', local]
    if !UnderRoot(remote, s_remote.root)
      add(command, '--allow-outside-root')
    endif
    if force
      add(command, '--force')
    endif
    if recursive
      add(command, '--recursive')
    endif
    return command
  endif
  var endpoint = s_remote.target .. ':' .. remote
  if s_remote.kind ==# 'docker'
    return direction ==# 'download'
      ? ['docker', 'cp', endpoint, local]
      : ['docker', 'cp', local, endpoint]
  endif
  var scp = ['scp', '-q'] + (recursive ? ['-r'] : [])
  return direction ==# 'download'
    ? scp + [endpoint, local]
    : scp + [local, endpoint]
enddef

def FinishTransfer(direction: string, remote: string, local: string,
    errors: list<string>, Callback: func, status: number)
  var ok = status == 0
  var detail = empty(errors) ? '' : errors[-1]
  var result = {
    direction: direction,
    remote: remote,
    local: local,
    status: status,
    error: ok ? '' : (empty(detail) ? printf('exit status %d', status) : detail),
  }
  if !ok
    if Callback == null_function
      Error(printf('[SimpleRemote] %s failed (%d): %s', direction, status,
        empty(detail) ? remote : detail))
    endif
  elseif direction ==# 'download'
    if Callback == null_function
      var copied = CopyText(local)
      echomsg printf('[SimpleRemote] copied %s -> %s%s', remote, local,
        copied ? '' : ' (path in unnamed register)')
    endif
    Emit('SimpleRemoteFileCopied', {remote: remote, local: local})
    if SimpleTreeVisible() && exists('*simpletree#GetRoot') == 1
          && exists(':SimpleTreeReveal') == 2
          && UnderRoot(local, simpletree#GetRoot())
      silent! execute 'SimpleTreeReveal ' .. fnameescape(local)
    elseif exists(':SimpleTreeRefresh') == 2
      silent! execute 'SimpleTreeRefresh'
    endif
  else
    if Callback == null_function
      echomsg printf('[SimpleRemote] uploaded %s -> %s', local, remote)
    endif
    Emit('SimpleRemoteFileUploaded', {remote: remote, local: local})
    AnnounceFilesChanged([{path: remote, type: 'created'}])
    if !empty(s_tree) && bufexists(get(s_tree, 'buf', -1))
      s_tree.reveal = remote
      ReloadRemoteTree()
    endif
  endif
  if Callback != null_function
    call(Callback, [ok, result])
  endif
enddef

# Start a transfer job.  Returns false when nothing was started (and the
# callback, if any, has already been told why).
def StartTransfer(direction: string, remote: string, local: string,
    options: dict<any> = {}, Callback: func = null_function): bool
  if !IsReady()
    if Callback != null_function
      call(Callback, [false, {error: 'remote workspace is not ready'}])
    else
      Error('[SimpleRemote] not connected')
    endif
    return false
  endif
  if direction ==# 'download' && !get(options, 'force', false)
        && !RuntimeHandlesTransfer(direction, options) && getftype(local) !=# ''
    # scp and docker cp overwrite silently; the runtime refuses an existing
    # destination unless forced, and the fallback must keep that promise.
    FinishTransfer(direction, remote, local,
      ['local destination already exists: ' .. local], Callback, 47)
    return true
  endif
  if direction ==# 'upload' && !get(options, 'force', false)
        && !RuntimeHandlesTransfer(direction, options)
    # The same promise in the other direction, checked remotely.
    var probe = 'if [ -e ' .. shellescape(remote) .. ' ] || [ -L '
      .. shellescape(remote) .. ' ]; then echo exists; fi'
    var settings = extend(copy(options), {force: true})
    Send('exec', {command: probe}, (ok, body) => {
      if ok && trim(body) ==# 'exists'
        FinishTransfer(direction, remote, local,
          ['remote destination already exists: ' .. remote], Callback, 47)
      else
        StartTransfer(direction, remote, local, settings, Callback)
      endif
    })
    return true
  endif
  var command = TransferCommand(direction, remote, local, options)
  var errors: list<string> = []
  var job = job_start(command, {
    in_io: 'null', out_io: 'null', err_io: 'pipe', err_mode: 'nl',
    err_cb: (_channel, line) => {
      if !empty(line)
        add(errors, line)
      endif
    },
    exit_cb: (_job, status) =>
      FinishTransfer(direction, remote, local, errors, Callback, status),
  })
  if job_status(job) ==# 'fail'
    if Callback != null_function
      call(Callback, [false, {error: 'cannot start ' .. direction}])
    else
      Error('[SimpleRemote] cannot start ' .. direction)
    endif
    return false
  endif
  if Callback == null_function
    echomsg direction ==# 'download'
      ? printf('[SimpleRemote] downloading %s -> %s', remote, local)
      : printf('[SimpleRemote] uploading %s -> %s', local, remote)
  endif
  return true
enddef

def NormalizeRemoteTarget(path: string): string
  var remote = substitute(path, '^remote://', '', '')
  if remote !~# '^/'
    remote = JoinRemotePath(s_remote.root, remote)
  endif
  return NormalizeTreeRoot(remote)
enddef

def CopyRemoteTreeFileOut()
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  var node = CurrentRemoteTreeNode()
  if empty(node) || empty(get(node, 'path', ''))
    return
  endif
  var recursive = get(node, 'type', '') ==# 'd'
  var directory = LocalCopyDirectory()
  var destination = empty(directory) ? ''
    : substitute(directory, '[\\/]\+$', '', '') .. '/' .. fnamemodify(node.path, ':t')
  if empty(destination) || get(g:, 'simpleremote_copy_prompt', 0)
    destination = input(recursive ? 'Copy remote directory to: '
      : 'Copy remote file to: ',
      empty(destination) ? expand('~/') .. fnamemodify(node.path, ':t') : destination,
      'file')
  endif
  if empty(destination)
    return
  endif
  destination = substitute(fnamemodify(destination, ':p'), '[\\/]\+$', '', '')
  var force = false
  if filereadable(destination) || isdirectory(destination)
    if isdirectory(destination) && !recursive
      Error('[SimpleRemote] destination is a directory: ' .. destination)
      return
    endif
    force = confirm('Replace local ' .. (recursive ? 'directory' : 'file')
      .. "?\n" .. destination, "&Replace\n&Cancel", 2) == 1
    if !force
      return
    endif
  endif
  StartTransfer('download', node.path, destination,
    {force: force, recursive: recursive})
enddef

# The local source of an upload: SimpleTree's selected node when a tree is
# showing, otherwise a prompt.
def LocalUploadSource(): string
  var selected = ''
  if exists('*simpletree#ExternalSelectedPath') == 1
    try
      selected = simpletree#ExternalSelectedPath()
    catch
      selected = ''
    endtry
  endif
  var source = input('Upload local path: ',
    empty(selected) ? '' : selected, 'file')
  return empty(source) ? '' : substitute(fnamemodify(source, ':p'), '[\\/]\+$', '', '')
enddef

def UploadFinished(local: string, remote: string, recursive: bool,
    ok: bool, result: dict<any>)
  if ok
    echomsg printf('[SimpleRemote] uploaded %s -> %s', local, remote)
    return
  endif
  var error = get(result, 'error', '')
  if error =~# 'already exists'
    if confirm('Replace remote ' .. (recursive ? 'directory' : 'file')
        .. "?\n" .. remote, "&Replace\n&Cancel", 2) == 1
      StartTransfer('upload', remote, local, {force: true, recursive: recursive})
    endif
    return
  endif
  Error('[SimpleRemote] upload failed: ' .. error)
enddef

def UploadToRemote(local: string, remote_directory: string)
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  if empty(local) || (!filereadable(local) && !isdirectory(local))
    Error('[SimpleRemote] local path is not a file or directory: ' .. local)
    return
  endif
  var recursive = isdirectory(local)
  var remote = JoinRemotePath(NormalizeRemoteTarget(remote_directory),
    fnamemodify(local, ':t'))
  StartTransfer('upload', remote, local, {recursive: recursive},
    (ok, result) => UploadFinished(local, remote, recursive, ok, result))
enddef

def UploadIntoRemoteTree()
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  var directory = RemoteTreeTargetDirectory()
  var local = LocalUploadSource()
  if empty(local)
    return
  endif
  UploadToRemote(local, directory)
enddef

# The window remote files open in: the current one when it holds an ordinary
# or remote buffer, otherwise the first such window in the tab, so a file
# never lands in a minimap, tree, or quickfix split.
def EditableWindow(): number
  var special = ['simpleminimap', 'simpletree', 'simpleremotetree', 'qf', 'help']
  if (&buftype ==# '' || &buftype ==# 'acwrite') && index(special, &filetype) < 0
    return win_getid()
  endif
  for window in getwininfo()
    if window.tabnr != tabpagenr()
      continue
    endif
    var buftype = getbufvar(window.bufnr, '&buftype')
    if (buftype ==# '' || buftype ==# 'acwrite')
          && index(special, getbufvar(window.bufnr, '&filetype')) < 0
      return window.winid
    endif
  endfor
  return 0
enddef

def OpenRemoteTree(path: string, reveal: string = '')
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  var existing = get(s_tree, 'buf', -1)
  if existing > 0 && bufexists(existing)
    var winid = bufwinid(existing)
    if winid > 0
      win_gotoid(winid)
    endif
    s_tree.reveal = reveal
    LoadRemoteTree(path)
    return
  endif
  var source_win = EditableWindow()
  if source_win == 0
    source_win = win_getid()
  endif
  var width = max([24, get(g:, 'simpleremote_tree_width', 40)])
  execute 'silent keepalt leftabove vnew ' .. fnameescape('[SimpleRemote]')
  execute 'vertical resize ' .. width
  var buf = bufnr()
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal nowrap nonumber norelativenumber signcolumn=no foldcolumn=0
  setlocal cursorline nomodified
  &l:filetype = 'simpleremotetree'
  &l:statusline = '%{g:SimpleRemoteTreeStatusline()}'
  SetupRemoteTreeSyntax()
  nnoremap <silent><buffer> q <Cmd>call g:SimpleRemoteTreeClose()<CR>
  nnoremap <silent><buffer> <Esc> <Cmd>call g:SimpleRemoteTreeClose()<CR>
  nnoremap <silent><buffer> <CR> <Cmd>call g:SimpleRemoteTreeActivate('edit')<CR>
  nnoremap <silent><buffer> o <Cmd>call g:SimpleRemoteTreeActivate('edit')<CR>
  nnoremap <silent><buffer> l <Cmd>call g:SimpleRemoteTreeActivate('edit')<CR>
  nnoremap <silent><buffer> <Right> <Cmd>call g:SimpleRemoteTreeActivate('edit')<CR>
  nnoremap <silent><buffer> <2-LeftMouse> <Cmd>call g:SimpleRemoteTreeActivate('edit')<CR>
  nnoremap <silent><buffer> S <Cmd>call g:SimpleRemoteTreeActivate('split')<CR>
  nnoremap <silent><buffer> v <Cmd>call g:SimpleRemoteTreeActivate('vsplit')<CR>
  nnoremap <silent><buffer> V <Cmd>call g:SimpleRemoteTreeActivate('vsplit')<CR>
  nnoremap <silent><buffer> t <Cmd>call g:SimpleRemoteTreeActivate('tabedit')<CR>
  nnoremap <silent><buffer> <C-x> <Cmd>call g:SimpleRemoteTreeActivate('split')<CR>
  nnoremap <silent><buffer> <C-v> <Cmd>call g:SimpleRemoteTreeActivate('vsplit')<CR>
  nnoremap <silent><buffer> <C-t> <Cmd>call g:SimpleRemoteTreeActivate('tabedit')<CR>
  nnoremap <silent><buffer> P <Cmd>call g:SimpleRemoteTreeActivate('pedit')<CR>
  nnoremap <silent><buffer> h <Cmd>call g:SimpleRemoteTreeParent()<CR>
  nnoremap <silent><buffer> <Left> <Cmd>call g:SimpleRemoteTreeParent()<CR>
  nnoremap <silent><buffer> <BS> <Cmd>call g:SimpleRemoteTreeParent()<CR>
  nnoremap <silent><buffer> R <Cmd>call g:SimpleRemoteTreeRefresh()<CR>
  nnoremap <silent><buffer> H <Cmd>call g:SimpleRemoteTreeToggleHidden()<CR>
  nnoremap <silent><buffer> I <Cmd>call g:SimpleRemoteTreeToggleGitIgnore()<CR>
  nnoremap <silent><buffer> s <Cmd>call g:SimpleRemoteTreeSortCycle()<CR>
  nnoremap <silent><buffer> gs <Cmd>call g:SimpleRemoteTreeSortReverse()<CR>
  nnoremap <silent><buffer> z <Cmd>call g:SimpleRemoteTreeCollapseAll()<CR>
  nnoremap <silent><buffer> F <Cmd>call g:SimpleRemoteTreeFilter()<CR>
  nnoremap <silent><buffer> f <Cmd>call g:SimpleRemoteTreeRevealActive()<CR>
  nnoremap <silent><buffer> / <Cmd>call g:SimpleRemoteTreeFind(1, 1)<CR>
  nnoremap <silent><buffer> ]f <Cmd>call g:SimpleRemoteTreeFind(0, 1)<CR>
  nnoremap <silent><buffer> [f <Cmd>call g:SimpleRemoteTreeFind(0, -1)<CR>
  nnoremap <silent><buffer> e <Cmd>call g:SimpleRemoteTreeRootHere()<CR>
  nnoremap <silent><buffer> U <Cmd>call g:SimpleRemoteTreeRootUp()<CR>
  nnoremap <silent><buffer> C <Cmd>call g:SimpleRemoteTreeRootPrompt()<CR>
  nnoremap <silent><buffer> . <Cmd>call g:SimpleRemoteTreeRootReset()<CR>
  nnoremap <silent><buffer> d <Cmd>call g:SimpleRemoteTreeRootCurrent()<CR>
  nnoremap <silent><buffer> L <Cmd>call g:SimpleRemoteTreeToggleRootLock()<CR>
  nnoremap <silent><buffer> ? <Cmd>call g:SimpleRemoteTreeHelp()<CR>
  nnoremap <silent><buffer> c <Cmd>call g:SimpleRemoteTreeCopy()<CR>
  nnoremap <silent><buffer> x <Cmd>call g:SimpleRemoteTreeCut()<CR>
  nnoremap <silent><buffer> p <Cmd>call g:SimpleRemoteTreePaste()<CR>
  nnoremap <silent><buffer> a <Cmd>call g:SimpleRemoteTreeNewFile()<CR>
  nnoremap <silent><buffer> n <Cmd>call g:SimpleRemoteTreeNewFile()<CR>
  nnoremap <silent><buffer> A <Cmd>call g:SimpleRemoteTreeNewFolder()<CR>
  nnoremap <silent><buffer> N <Cmd>call g:SimpleRemoteTreeNewFolder()<CR>
  nnoremap <silent><buffer> r <Cmd>call g:SimpleRemoteTreeRename()<CR>
  nnoremap <silent><buffer> D <Cmd>call g:SimpleRemoteTreeDelete()<CR>
  nnoremap <silent><buffer> <Space> <Cmd>call g:SimpleRemoteTreeMarkToggle()<CR>
  xnoremap <silent><buffer> <Space> :<C-u>call g:SimpleRemoteTreeMarkRange(line("'<"), line("'>"))<CR>
  nnoremap <silent><buffer> gm <Cmd>call g:SimpleRemoteTreeMarkSiblings()<CR>
  nnoremap <silent><buffer> gM <Cmd>call g:SimpleRemoteTreeMarkClear()<CR>
  nnoremap <silent><buffer> m <Cmd>call g:SimpleRemoteTreeBookmarkToggle()<CR>
  nnoremap <silent><buffer> ' <Cmd>call g:SimpleRemoteTreeBookmarkList()<CR>
  nnoremap <silent><buffer> ]b <Cmd>call g:SimpleRemoteTreeBookmarkCycle(1)<CR>
  nnoremap <silent><buffer> [b <Cmd>call g:SimpleRemoteTreeBookmarkCycle(-1)<CR>
  nnoremap <silent><buffer> y <Cmd>call g:SimpleRemoteTreeYank(0)<CR>
  nnoremap <silent><buffer> Y <Cmd>call g:SimpleRemoteTreeYank(1)<CR>
  nnoremap <silent><buffer> gy <Cmd>call g:SimpleRemoteTreeCopyContents()<CR>
  nnoremap <silent><buffer> gd <Cmd>call g:SimpleRemoteTreeCopyOut()<CR>
  nnoremap <silent><buffer> gu <Cmd>call g:SimpleRemoteTreeUpload()<CR>
  DescribeTreeKeys()
  s_tree = {
    buf: buf,
    source_win: source_win,
    reveal: reveal,
    root: path,
    epoch: 1,
    cache: {},
    loading: {},
    errors: {},
    git: {},
    git_ignored: {},
    git_ignore: !!get(g:, 'simpleremote_tree_git_ignore', 1),
    expanded: {path: true},
    find_query: '',
    filter_query: '',
    marked: {},
    sort: get(g:, 'simpleremote_tree_sort', 'name'),
    sort_reverse: !!get(g:, 'simpleremote_tree_sort_reverse', 0),
    metadata_supported: -1,
    root_locked: !!get(g:, 'simpleremote_tree_root_locked', 1),
  }
  LoadRemoteTree(path)
enddef

def ActiveRemotePath(): string
  if !IsReady()
    return ''
  endif
  var info = get(b:, 'vimrc_remote', {})
  var path = type(info) == v:t_dict ? get(info, 'path', '') : ''
  if empty(path)
    path = get(b:, 'simpleremote_path', '')
  endif
  return type(path) == v:t_string && UnderRoot(path, s_remote.root) ? path : ''
enddef

def RevealSimpleTree(path: string)
  if empty(path) || exists(':SimpleTreeReveal') != 2
    return
  endif
  execute 'SimpleTreeReveal ' .. fnameescape(path)
enddef

def OpenWorkspaceTree(reveal: string = '')
  if empty(s_remote) || !IsReady()
    if exists(':SimpleTree') == 2
      execute 'SimpleTree'
    elseif exists(':Explore') == 2
      execute 'Explore'
    endif
    return
  endif
  var local_root = get(s_remote, 'local_root', '')
  if !empty(local_root)
    var remote_tree_root = get(s_remote, 'tree_root', s_remote.root)
    if !UnderRoot(remote_tree_root, s_remote.root)
      OpenRemoteTree(remote_tree_root)
      return
    endif
    var local_tree_root = RemoteTreeLocalPath(remote_tree_root)
    CloseRemoteTree()
    if exists(':SimpleTree') == 2
      if SimpleTreeVisible() && SetSimpleTreeRoot(local_tree_root)
        if !empty(reveal) && UnderRoot(reveal, s_remote.root)
          RevealSimpleTree(RemoteTreeLocalPath(reveal))
        endif
        return
      endif
      execute 'SimpleTree ' .. fnameescape(local_tree_root)
      if !empty(reveal) && UnderRoot(reveal, s_remote.root)
        RevealSimpleTree(RemoteTreeLocalPath(reveal))
      endif
    elseif exists(':Explore') == 2
      execute 'Explore ' .. fnameescape(local_tree_root)
    endif
    return
  endif
  # The virtual tree cannot rely on SimpleTree's local-path reveal.  Root its
  # view at the active file's parent so the first asynchronous listing already
  # contains the row that must receive focus.  This changes only the view, not
  # the connected workspace root.
  if !empty(reveal) && UnderRoot(reveal, s_remote.root)
    OpenRemoteTree(RemoteParent(reveal), reveal)
  else
    OpenRemoteTree(get(s_remote, 'tree_root', s_remote.root))
  endif
enddef

# Put the cursor in a window a file may be opened in: the tree's own source
# window when it is still there, else any ordinary window, else a new split —
# never the tree itself, whose buffer is wiped when it is replaced.
def FocusEditWindow()
  var source_win = get(s_tree, 'source_win', 0)
  if source_win > 0 && win_id2win(source_win) > 0
    win_gotoid(source_win)
    if EditableWindow() == win_getid()
      return
    endif
  endif
  var editable = EditableWindow()
  if editable > 0
    win_gotoid(editable)
  else
    botright new
  endif
  if !empty(s_tree)
    s_tree.source_win = win_getid()
  endif
enddef

def RemoteTreeActivate(action: string)
  var nodes = get(b:, 'simpleremote_tree_nodes', [])
  var index = line('.') - 1
  if index < 0 || index >= len(nodes) || empty(nodes[index])
    return
  endif
  var node = nodes[index]
  if node.type ==# 'd'
    if get(node, 'expanded', false)
      remove(s_tree.expanded, node.path)
      RenderRemoteTree(s_tree.buf)
    else
      s_tree.expanded[node.path] = true
      LoadTreeDirectory(node.path)
    endif
    return
  endif
  FocusEditWindow()
  if action ==# 'edit'
    OpenRemote(node.path)
  else
    execute action .. ' ' .. fnameescape('remote://' .. node.path)
  endif
enddef

def CollapseRemoteTreeNode()
  var nodes = get(b:, 'simpleremote_tree_nodes', [])
  var index = line('.') - 1
  if index < 0 || index >= len(nodes) || empty(nodes[index])
    return
  endif
  var node = nodes[index]
  var collapse = node.type ==# 'd' && get(node, 'expanded', false)
    ? node.path : get(node, 'parent', '')
  if empty(collapse) || collapse ==# s_tree.root
    return
  endif
  if has_key(s_tree.expanded, collapse)
    remove(s_tree.expanded, collapse)
  endif
  s_tree.reveal = collapse
  RenderRemoteTree(s_tree.buf)
enddef

def RemoteActions(result: number)
  if result <= 0
    return
  endif
  if result == 1
    OpenWorkspaceTree()
  elseif result == 2
    g:SimpleRemoteTerminal()
  elseif result == 3
    g:VimrcRemotePromptFind()
  elseif result == 4
    g:SimpleRemoteReconnect()
  elseif result == 5
    g:SimpleRemoteShowStatus()
  elseif result == 6
    g:VimrcRemoteHealth()
  elseif result == 7
    g:SimpleRemoteInstallAgent()
  elseif result == 8
    Disconnect()
  endif
enddef

def OpenRemoteUI()
  if !IsReady()
    PickTargets()
    return
  endif
  var actions = [
    'Workspace tree',
    'Remote terminal',
    'Find remote file',
    'Reconnect',
    'Connection status',
    'Health check',
    'Install/update agent',
    'Disconnect',
  ]
  if exists('*popup_menu') == 1
    popup_menu(actions, {
      title: ' SimpleRemote ',
      callback: (_id, result) => RemoteActions(result),
      minwidth: 36,
    })
  else
    RemoteActions(inputlist(['SimpleRemote:'] + actions))
  endif
enddef

def InstallAgent(spec: dict<any>)
  var source = AgentSourcePath()
  if !filereadable(source)
    Error('[SimpleRemote] bundled agent is missing: ' .. source)
    return
  endif
  var agent = AgentPath()
  var destination = strpart(agent, 0, 2) ==# '~/'
    ? '"$HOME"/' .. shellescape(strpart(agent, 2))
    : shellescape(agent)
  var script = 'set -eu; dst=' .. destination
    .. '; dir=$(dirname -- "$dst"); umask 077; mkdir -p "$dir"; '
    .. 'tmp="$dst.tmp.$$"; trap ''rm -f "$tmp"'' EXIT HUP INT TERM; '
    .. 'cat > "$tmp"; chmod 700 "$tmp"; mv -f "$tmp" "$dst"; trap - EXIT'
  var command: list<string>
  if spec.kind ==# 'docker'
    command = ['docker', 'exec', '-i', spec.target, 'sh', '-c', script]
  else
    command = ['ssh', '-T', spec.target, 'sh', '-c', ShellLiteral(script)]
  endif
  var content = join(readfile(source, 'b'), "\n") .. "\n"
  system(ShellCommand(command), content)
  if v:shell_error == 0
    echomsg printf('[SimpleRemote] agent installed on %s:%s',
      spec.kind, spec.target)
  else
    Error('[SimpleRemote] agent installation failed')
  endif
enddef

def g:SimpleRemoteUI()
  OpenRemoteUI()
enddef

def g:SimpleRemoteConnect(kind: string, target: string, root: string)
  Connect(kind, target, root, {kind: kind, target: target, root: root})
enddef

def g:SimpleRemoteConnectCommand(...args: list<string>)
  if empty(args)
    PickTargets()
    return
  endif
  if len(args) == 1
    for spec in ConfiguredProfiles()
      if get(spec, 'name', '') ==# args[0]
        ConnectSpec(spec)
        return
      endif
    endfor
    ConnectSpec({kind: 'ssh', target: args[0], root: ''})
    return
  endif
  if len(args) == 2
    ConnectSpec({kind: args[0], target: args[1], root: ''})
    return
  endif
  ConnectSpec({kind: args[0], target: args[1], root: join(args[2 :], ' ')})
enddef

def g:SimpleRemoteReconnect()
  var spec = !empty(s_remote)
    ? extend(copy(get(s_remote, 'options', {})), {
        kind: s_remote.kind, target: s_remote.target, root: s_remote.root,
      }, 'force')
    : copy(s_last_spec)
  if empty(spec)
    PickTargets()
  else
    ConnectSpec(spec)
  endif
enddef

def g:SimpleRemoteShowStatus()
  if empty(s_remote)
    echomsg '[SimpleRemote] disconnected'
    return
  endif
  var workspace = WorkspaceSnapshot()
  var probe = get(workspace, 'probe', {})
  var latency = get(probe, 'runtime_ms', '')
  echomsg printf('[SimpleRemote] %s %s:%s [%s]%s%s',
    workspace.kind, workspace.target, workspace.root, workspace.mode,
    empty(workspace.local_root) ? '' : ' -> ' .. workspace.local_root,
    empty(latency) ? '' : '  ' .. latency .. 'ms')
  echomsg printf('[SimpleRemote] transport=%s runtime=%s',
    workspace.protocol,
    empty(workspace.runtime) ? 'none'
      : (empty(workspace.runtime_version) ? 'unknown' : workspace.runtime_version))
  if !empty(probe)
    echomsg printf('[SimpleRemote] host=%s python=%s lsp=%s%s',
      get(probe, 'host', '?'), get(probe, 'python', 'missing'),
      get(probe, 'python_lsp', 'missing'),
      empty(get(probe, 'uname', '')) ? '' : ' os=' .. probe.uname)
  endif
enddef

def g:SimpleRemoteProbe()
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  StartRuntimeProbe(s_remote.generation)
  echomsg '[SimpleRemote] runtime probe started'
enddef

def g:SimpleRemoteTreeToggle()
  var buf = get(s_tree, 'buf', -1)
  if buf > 0 && bufwinid(buf) > 0
    CloseRemoteTree()
  else
    # Capture before opening/focusing the tree changes the current buffer.
    # A remote:// buffer is not a real local path, so projected workspaces
    # explicitly translate it before asking SimpleTree to reveal the row.
    OpenWorkspaceTree(ActiveRemotePath())
  endif
enddef

def g:SimpleRemoteTreeReveal()
  if !IsReady() || bufname() !~# '^remote://'
    if exists(':SimpleTreeReveal') == 2
      execute 'SimpleTreeReveal'
    else
      OpenWorkspaceTree()
    endif
    return
  endif
  var path = get(get(b:, 'vimrc_remote', {}), 'path', '')
  if !empty(path)
    OpenRemoteTree(RemoteParent(path), path)
  endif
enddef

def g:SimpleRemoteTreeActivate(action: string = 'edit')
  RemoteTreeActivate(action)
enddef

def g:SimpleRemoteTreeParent()
  CollapseRemoteTreeNode()
enddef

def g:SimpleRemoteTreeRefresh()
  RefreshRemoteTree()
enddef

def g:SimpleRemoteTreeRootHere()
  RemoteTreeRootHere()
enddef

def g:SimpleRemoteTreeRootUp()
  RemoteTreeRootUp()
enddef

def g:SimpleRemoteTreeRootPrompt()
  RemoteTreeRootPrompt()
enddef

def g:SimpleRemoteTreeRootReset()
  RemoteTreeRootReset()
enddef

def g:SimpleRemoteTreeHelp()
  RemoteTreeHelp()
enddef

def g:SimpleRemoteTreeToggleHidden()
  RemoteTreeToggleHidden()
enddef

def g:SimpleRemoteTreeToggleGitIgnore()
  RemoteTreeToggleGitIgnore()
enddef

def g:SimpleRemoteTreeFilter()
  RemoteTreeFilter()
enddef

def g:SimpleRemoteTreeSortCycle()
  RemoteTreeSortCycle()
enddef

def g:SimpleRemoteTreeSortReverse()
  RemoteTreeSortReverse()
enddef

def g:SimpleRemoteTreeCollapseAll()
  RemoteTreeCollapseAll()
enddef

def g:SimpleRemoteTreeFind(ask: number, direction: number)
  RemoteTreeFind(ask != 0, direction)
enddef

def g:SimpleRemoteTreeRevealActive()
  RemoteTreeRevealActive()
enddef

def g:SimpleRemoteTreeRootCurrent()
  RemoteTreeRootCurrent()
enddef

def g:SimpleRemoteTreeToggleRootLock()
  RemoteTreeToggleRootLock()
enddef

def g:SimpleRemoteTreeSetRoot(path: string): bool
  return SetRemoteTreeRoot(path)
enddef

def g:SimpleRemoteOnSimpleTreeRootChanged()
  if !IsReady() || empty(get(s_remote, 'local_root', ''))
    return
  endif
  var event = get(g:, 'simpletree_event', {})
  if type(event) != v:t_dict || get(event, 'source', '') ==# 'simpleremote'
    return
  endif
  var local = get(event, 'root', get(event, 'path', ''))
  if empty(local)
    return
  endif
  local = substitute(resolve(fnamemodify(local, ':p')), '[\\/]\+$', '', '')
  if UnderRoot(local, s_remote.local_root)
    var suffix = strpart(local, len(s_remote.local_root))
    var remote = s_remote.root ==# '/'
      ? '/' .. substitute(suffix, '^/', '', '') : s_remote.root .. suffix
    QueueWorkspaceRoot(remote, local, 'simpletree')
    return
  endif

  # `U` from the projection root lands briefly in the mountpoint's local
  # parent.  Its lexical path is not a projection, but the event carries enough
  # intent to move the remote workspace up and let projection discovery mount
  # the corresponding directory.
  var old_local = get(event, 'old_root', '')
  if get(event, 'source', '') ==# 'up' && !empty(old_local)
    old_local = substitute(resolve(fnamemodify(old_local, ':p')),
      '[\\/]\+$', '', '')
    if old_local ==# substitute(s_remote.local_root, '[\\/]\+$', '', '')
          && local ==# fnamemodify(old_local, ':h')
      QueueWorkspaceRoot(RemoteParent(s_remote.root), local, 'simpletree')
    endif
  endif
enddef

def g:SimpleRemoteTreeYank(absolute: number)
  YankRemoteTreeValue(absolute != 0)
enddef

def g:SimpleRemoteTreeCopyContents()
  CopyRemoteTreeContents()
enddef

def g:SimpleRemoteTreeCopy()
  RemoteTreeClipboard('copy')
enddef

def g:SimpleRemoteTreeCut()
  RemoteTreeClipboard('cut')
enddef

def g:SimpleRemoteTreePaste()
  RemoteTreePaste()
enddef

def g:SimpleRemoteTreeNewFile()
  RemoteTreeNew(false)
enddef

def g:SimpleRemoteTreeNewFolder()
  RemoteTreeNew(true)
enddef

def g:SimpleRemoteTreeRename()
  RemoteTreeRename()
enddef

def g:SimpleRemoteTreeDelete()
  RemoteTreeDelete()
enddef

def g:SimpleRemoteTreeMarkToggle()
  RemoteTreeMarkToggle()
enddef

def g:SimpleRemoteTreeMarkRange(first: number, last: number)
  RemoteTreeMarkRange(first, last)
enddef

def g:SimpleRemoteTreeMarkSiblings()
  RemoteTreeMarkSiblings()
enddef

def g:SimpleRemoteTreeMarkClear()
  RemoteTreeMarkClear()
enddef

def g:SimpleRemoteTreeBookmarkToggle()
  RemoteTreeBookmarkToggle()
enddef

def g:SimpleRemoteTreeBookmarkList()
  RemoteTreeBookmarkList()
enddef

def g:SimpleRemoteTreeBookmarkCycle(direction: number)
  RemoteTreeBookmarkCycle(direction)
enddef

def g:SimpleRemoteTreeCopyOut()
  CopyRemoteTreeFileOut()
enddef

def g:SimpleRemoteTreeClose()
  CloseRemoteTree()
enddef

def g:SimpleRemoteTreeStatusline(): string
  var latency = get(get(s_remote, 'runtime_probe', {}), 'runtime_ms', '')
  var flags: list<string> = []
  if !get(g:, 'simpleremote_tree_show_hidden', 1)
    add(flags, 'hidden:off')
  endif
  if !get(s_tree, 'git_ignore', true)
    add(flags, 'gitignore:off')
  endif
  if get(s_tree, 'root_locked', false)
    add(flags, 'locked')
  endif
  var filter_query = get(s_tree, 'filter_query', '')
  if !empty(filter_query)
    add(flags, 'filter:' .. filter_query)
  endif
  var sort = TreeSortMode()
  if sort !=# 'name' || get(s_tree, 'sort_reverse', false)
    add(flags, 'sort:' .. sort .. (get(s_tree, 'sort_reverse', false) ? ':rev' : ''))
  endif
  if !empty(get(s_tree, 'marked', {}))
    add(flags, 'marked:' .. len(s_tree.marked))
  endif
  var query = get(s_tree, 'find_query', '')
  if !empty(query)
    add(flags, 'find:' .. query)
  endif
  if get(s_remote, 'tree_root', s_remote.root) !=# s_remote.root
    add(flags, 'detached-root')
  endif
  var detail = empty(flags) ? '' : '  [' .. join(flags, ' ') .. ']'
  return empty(s_remote) ? ' SimpleRemote ' : printf(' %s:%s%s  %s%s  [? keys] ',
    s_remote.kind, s_remote.target,
    empty(latency) ? '' : '@' .. latency .. 'ms',
    get(b:, 'simpleremote_tree_path', s_remote.root), detail)
enddef

def g:SimpleRemoteTerminalSpec(argument: string = ''): dict<any>
  if !IsReady()
    return {}
  endif
  var command: list<string>
  var daemon = DaemonPath()
  var shell = empty(argument)
    ? 'exec "${SHELL:-sh}" -l'
    : 'exec "${SHELL:-sh}" -lc ' .. shellescape(argument)
  if !empty(daemon) && RuntimeSupports('tty')
    # The runtime shares the ControlMaster connection and applies the same
    # PATH prelude the language servers get, so the shell sees .venv/bin,
    # ~/.local/bin and friends without sourcing anything itself.
    command = [daemon, 'exec', '--tty', '--kind', s_remote.kind,
      '--target', s_remote.target, '--root', s_remote.root,
      '--', 'sh', '-c', shell]
  elseif s_remote.kind ==# 'docker'
    command = ['docker', 'exec', '-it', '-w', s_remote.root, s_remote.target,
      'sh']
    if !empty(argument)
      extend(command, ['-lc', argument])
    endif
  else
    var script = 'cd ' .. shellescape(s_remote.root) .. ' && ' .. shell
    command = ['ssh', '-t', s_remote.target, 'sh', '-lc', ShellLiteral(script)]
  endif
  return {
    command: command,
    cwd: '',
    name: printf('%s:%s:%s', s_remote.kind, s_remote.target,
      fnamemodify(s_remote.root, ':t')),
    remote: true,
    workspace: copy(get(g:, 'simpleremote_workspace', {})),
  }
enddef

def g:SimpleRemoteTerminal(command: string = '')
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  if exists(':SimpleTerminalNew') == 2
    execute 'SimpleTerminalNew ' .. command
    return
  endif
  var spec = g:SimpleRemoteTerminalSpec(command)
  botright new
  term_start(spec.command, {
    curwin: true,
    term_name: 'SimpleRemote:' .. spec.name,
  })
  startinsert
enddef

def g:SimpleRemoteInstallAgent()
  var spec = !empty(s_remote) ? {
    kind: s_remote.kind, target: s_remote.target, root: s_remote.root,
  } : copy(s_last_spec)
  if empty(spec)
    Error('[SimpleRemote] select or connect to a target first')
    return
  endif
  InstallAgent(spec)
enddef

def g:SimpleRemoteWorkspace(path: string = '')
  if !IsReady()
    PickTargets()
  elseif empty(path)
    OpenWorkspaceTree()
  elseif path =~# '^/'
    Connect(s_remote.kind, s_remote.target, path, copy(s_remote.options))
  else
    Error('[SimpleRemote] workspace folder must be absolute')
  endif
enddef

def g:SimpleRemoteActivateLocalBuffer()
  if !IsReady() || empty(get(s_remote, 'local_root', '')) || &buftype !=# ''
    return
  endif
  var local_path = substitute(resolve(expand('%:p')), '[\\/]\+$', '', '')
  if !UnderRoot(local_path, s_remote.local_root)
    return
  endif
  var suffix = strpart(local_path, len(s_remote.local_root))
  b:simpleremote_workspace_id = s_remote.generation
  b:simpleremote_path = s_remote.root ==# '/'
    ? '/' .. substitute(suffix, '^/', '', '')
    : s_remote.root .. suffix
enddef

def g:SimpleRemoteRecentWorkspaces(limit: number = -1): list<dict<any>>
  var result: list<dict<any>> = []
  if limit == 0
    return result
  endif

  for value in RecentSpecs()
    var spec = NormalizeSpec(value)
    if empty(spec) || get(spec, 'root', '') !~# '^/'
      continue
    endif
    add(result, {
      name: get(spec, 'name', ''),
      kind: spec.kind,
      target: spec.target,
      root: spec.root,
      local_root: get(spec, 'local_root', ''),
    })
    if limit >= 0 && len(result) >= limit
      break
    endif
  endfor
  return result
enddef

# Configured profiles in the same shape as recent workspaces, for dashboards
# and pickers.  A profile may omit its root; opening it then prompts.
def g:SimpleRemoteProfiles(): list<dict<any>>
  var result: list<dict<any>> = []
  for spec in ConfiguredProfiles()
    add(result, {
      name: get(spec, 'name', ''),
      kind: spec.kind,
      target: spec.target,
      root: get(spec, 'root', ''),
      local_root: get(spec, 'local_root', ''),
      source: 'profile',
    })
  endfor
  return result
enddef

def g:SimpleRemoteOpenWorkspace(workspace: dict<any>)
  var spec = NormalizeSpec(workspace)
  var root = get(spec, 'root', '')
  if empty(spec) || (root !~# '^/' && !(empty(root)
        && get(spec, 'source', '') ==# 'profile'))
    Error('[SimpleRemote] invalid recent workspace')
    return
  endif
  spec.open_tree = true
  ConnectSpec(spec)
enddef

# The argv prefix that runs a program in the workspace root, for callers that
# hand the runtime a real argv (every element quoted for the remote shell)
# rather than a shell script: append the program and its arguments.  Empty
# when no argv-safe transport exists, which is the case for plain ssh without
# the runtime (OpenSSH re-joins arguments through the login shell).
def g:SimpleRemoteExecArgv(): list<string>
  if !IsReady()
    return []
  endif
  var daemon = DaemonPath()
  if !empty(daemon)
    return [daemon, 'exec', '--kind', s_remote.kind,
      '--target', s_remote.target, '--root', s_remote.root, '--']
  endif
  if s_remote.kind ==# 'docker'
    return ['docker', 'exec', '-i', '-w', s_remote.root, s_remote.target]
  endif
  return []
enddef

# Lines a session file needs to bring this workspace back.  SimpleStartify
# appends them to its session files (g:simplestartify_session_line_providers);
# on load the global is picked up by the SimpleStartifySessionLoadPost hook
# below, which reconnects and re-reads every remote:// buffer the session
# restored as an empty shell.
def g:SimpleRemoteSessionLines(): list<string>
  if !IsReady()
    return []
  endif
  var spec = {
    name: get(s_remote.options, 'name', ''),
    kind: s_remote.kind,
    target: s_remote.target,
    root: s_remote.root,
    local_root: get(s_remote.options, 'local_root', ''),
  }
  return ['let g:simpleremote_session_workspace = ' .. string(spec)]
enddef

def ReloadRemoteBuffersAfterConnect(generation: number = -1)
  var owner = generation >= 0
    ? generation : empty(s_remote) ? -1 : s_remote.generation
  for info in getbufinfo({bufloaded: 1})
    if !IsCurrent(owner) || !IsReady()
      return
    endif
    if info.name !~# '^remote://' || get(info, 'changed', 0)
      continue
    endif
    var path = substitute(info.name, '^remote://', '', '')
    if !UnderRoot(path, s_remote.root)
      continue
    endif
    var winid = bufwinid(info.bufnr)
    if winid > 0
      win_execute(winid, 'silent! edit')
    else
      # Unloaded, the buffer goes through its BufReadCmd (ReadRemote) again
      # the next time a window shows it.
      execute 'silent! bunload ' .. info.bufnr
    endif
    if !IsCurrent(owner) || !IsReady()
      return
    endif
  endfor
enddef

def g:SimpleRemoteRestoreSessionWorkspace()
  var spec = get(g:, 'simpleremote_session_workspace', {})
  unlet! g:simpleremote_session_workspace
  if type(spec) != v:t_dict || empty(spec)
    return
  endif
  var normalized = NormalizeSpec(spec)
  if empty(normalized) || get(normalized, 'root', '') !~# '^/'
    return
  endif
  if IsReady() && s_remote.kind ==# normalized.kind
        && s_remote.target ==# normalized.target
        && s_remote.root ==# normalized.root
    ReloadRemoteBuffersAfterConnect()
    return
  endif
  augroup SimpleRemoteSessionRestore
    autocmd!
    autocmd User SimpleRemoteConnected ++once call g:SimpleRemoteReloadSessionBuffers()
  augroup END
  normalized.open_tree = false
  ConnectSpec(normalized)
enddef

def g:SimpleRemoteReloadSessionBuffers()
  # Called from the Connected autocmd: `:edit` from inside an autocmd would not
  # trigger the BufReadCmd that actually fetches the file, so leave the
  # autocmd context first.
  var generation = empty(s_remote) ? -1 : s_remote.generation
  timer_start(0, (_) => {
    if IsCurrent(generation) && IsReady()
      ReloadRemoteBuffersAfterConnect(generation)
    endif
  })
enddef

def g:SimpleRemoteWorkspaceRoot(): string
  return empty(s_remote) ? '' : s_remote.root
enddef

def g:SimpleRemoteProjectRoot(_path: string = ''): string
  if empty(s_remote)
    return ''
  endif
  return empty(get(s_remote, 'local_root', ''))
    ? s_remote.root : s_remote.local_root
enddef

def g:SimpleRemoteIsVirtual(): bool
  return IsReady() && empty(get(s_remote, 'local_root', ''))
enddef

def g:SimpleRemoteLocalPath(remote_path: string): string
  if empty(s_remote) || empty(get(s_remote, 'local_root', ''))
        || !UnderRoot(remote_path, s_remote.root)
    return ''
  endif
  return s_remote.local_root .. strpart(remote_path, len(s_remote.root))
enddef

def g:SimpleRemoteRemotePath(local_path: string): string
  if empty(s_remote) || empty(get(s_remote, 'local_root', ''))
        || !UnderRoot(local_path, s_remote.local_root)
    return ''
  endif
  return s_remote.root .. strpart(local_path, len(s_remote.local_root))
enddef

def g:SimpleRemoteShellCommand(command: string): list<string>
  if !IsReady()
    return []
  endif
  var daemon = DaemonPath()
  if !empty(daemon)
    return [daemon, 'exec', '--kind', s_remote.kind,
      '--target', s_remote.target, '--root', s_remote.root,
      '--', 'sh', '-c', command]
  endif
  var script = 'cd ' .. shellescape(s_remote.root) .. ' && ' .. command
  return s_remote.kind ==# 'docker'
    ? ['docker', 'exec', '-i', s_remote.target, 'sh', '-c', script]
    : ['ssh', '-T', s_remote.target, 'sh', '-c', ShellLiteral(script)]
enddef

# Read a text file from the active workspace without opening a buffer.  The
# callback receives (ok, content-or-error).  This is intentionally asynchronous:
# consumers such as SimpleFinder can update a preview while keeping Vim's UI
# responsive, and they reuse the persistent agent connection instead of opening
# another SSH session for every cursor movement.
def g:SimpleRemoteReadFile(path: string, Callback: func): number
  if !IsReady()
    call(Callback, [false, 'remote workspace is not ready'])
    return -1
  endif
  var remote_path = substitute(path, '^remote://', '', '')
  if remote_path !~# '^/'
    remote_path = JoinRemotePath(s_remote.root, remote_path)
  endif
  remote_path = NormalizeTreeRoot(remote_path)
  if !UnderRoot(remote_path, s_remote.root)
    call(Callback, [false, 'remote path is outside the active workspace'])
    return -1
  endif
  return Send('read', {path: remote_path}, (ok, body) => {
    call(Callback, [ok, body])
  })
enddef

# Run a shell command in the workspace root over the persistent agent
# connection and deliver its combined output.  Callback is (ok, output).
# Cheaper than job_start(g:SimpleRemoteShellCommand()) for short commands
# because no new transport session is opened; use the latter for streaming
# or long-running processes.
def g:SimpleRemoteExecute(command: string, Callback: func): number
  if !IsReady()
    call(Callback, [false, 'remote workspace is not ready'])
    return -1
  endif
  return Send('exec', {command: 'cd ' .. shellescape(s_remote.root)
    .. ' && ' .. command}, Callback)
enddef

# Write a text file inside the active workspace atomically.  Callback is
# (ok, path-or-error).
def g:SimpleRemoteWriteFile(path: string, content: string,
    Callback: func): number
  if !IsReady()
    call(Callback, [false, 'remote workspace is not ready'])
    return -1
  endif
  var remote_path = NormalizeRemoteTarget(path)
  if empty(remote_path) || !UnderRoot(remote_path, s_remote.root)
    call(Callback, [false, 'remote path is outside the active workspace'])
    return -1
  endif
  return Send('write', {path: remote_path, content: content}, (ok, body) => {
    if ok
      AnnounceFilesChanged([{path: remote_path, type: 'changed'}])
    endif
    call(Callback, [ok, body])
  })
enddef

# A multi-line dict literal inside a lambda block does not compile (E723) and
# takes the enclosing function down silently, so listing rows are built here.
def ParseDirectoryListing(remote_path: string, body: string,
    encoded: bool = false): list<dict<any>>
  var entries: list<dict<any>> = []
  for line in split(body, '\n')
    var fields = split(line, "\t", 1)
    if len(fields) < 2 || empty(fields[0])
      continue
    endif
    var name = ListingName(fields[0], encoded)
    if empty(name)
      continue
    endif
    add(entries, {
      name: name,
      path: JoinRemotePath(remote_path, name),
      type: fields[1],
      size: len(fields) > 2 ? str2nr(fields[2]) : -1,
      mtime: len(fields) > 3 ? str2nr(fields[3]) : -1,
    })
  endfor
  return entries
enddef

# List a workspace directory.  Callback is (ok, entries-or-error) where each
# entry is {name, path, type ('f'|'d'|'l'), size, mtime}; size/mtime are -1
# with an agent too old for list-meta.
def g:SimpleRemoteListDirectory(path: string, Callback: func): number
  if !IsReady()
    call(Callback, [false, 'remote workspace is not ready'])
    return -1
  endif
  var remote_path = NormalizeRemoteTarget(path)
  if empty(remote_path) || !UnderRoot(remote_path, s_remote.root)
    call(Callback, [false, 'remote path is outside the active workspace'])
    return -1
  endif
  return SendDirectoryListing(remote_path, true, (ok, body, info) => {
    call(Callback, [ok,
      ok ? ParseDirectoryListing(remote_path, body,
        !!get(info, 'encoded', false)) : body])
  })
enddef

# Stream a remote file (or, with {recursive: true}, directory) into a local
# path.  Options: force, recursive.  Callback is (ok, {remote, local, error}).
def g:SimpleRemoteDownload(remote_path: string, local_path: string,
    options: dict<any> = {}, Callback: func = null_function): bool
  if !IsReady()
    if Callback != null_function
      call(Callback, [false, {error: 'remote workspace is not ready'}])
    endif
    return false
  endif
  var remote = NormalizeRemoteTarget(remote_path)
  var local = substitute(fnamemodify(local_path, ':p'), '[\\/]\+$', '', '')
  if empty(remote) || empty(local)
    if Callback != null_function
      call(Callback, [false, {error: 'remote and local paths are required'}])
    endif
    return false
  endif
  return StartTransfer('download', remote, local, options, Callback)
enddef

# Stream a local file (or, with {recursive: true}, directory) into a remote
# path.  Options: force, recursive.  Callback is (ok, {remote, local, error}).
def g:SimpleRemoteUpload(local_path: string, remote_path: string,
    options: dict<any> = {}, Callback: func = null_function): bool
  if !IsReady()
    if Callback != null_function
      call(Callback, [false, {error: 'remote workspace is not ready'}])
    endif
    return false
  endif
  var local = substitute(fnamemodify(local_path, ':p'), '[\\/]\+$', '', '')
  var remote = NormalizeRemoteTarget(remote_path)
  if empty(remote) || empty(local)
    if Callback != null_function
      call(Callback, [false, {error: 'remote and local paths are required'}])
    endif
    return false
  endif
  var settings = copy(options)
  if !has_key(settings, 'recursive')
    settings.recursive = isdirectory(local)
  endif
  return StartTransfer('upload', remote, local, settings, Callback)
enddef

# Point every buffer under {source} at {target}, the way a tree rename does.
# Exposed so a caller that renames through its own means — a terminal, a
# script, another plugin — can keep the open buffers coherent.
def g:SimpleRemoteRetargetBuffers(source: string, target: string)
  if IsReady()
    RetargetRemoteBuffers(source, target)
  endif
enddef

def g:SimpleRemoteRuntimeCapabilities(): dict<any>
  return copy(RuntimeCapabilities())
enddef

def g:SimpleRemoteTreeUpload()
  UploadIntoRemoteTree()
enddef

# `gu` inside a SimpleTree buffer: push the selected local node into the
# remote workspace.  The destination defaults to the remote tree's selected
# directory when that tree is open, else the workspace root.
def g:SimpleRemoteUploadFromTree()
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  var local = LocalUploadSource()
  if empty(local)
    return
  endif
  var default = s_remote.root
  var tree_buf = get(s_tree, 'buf', -1)
  if tree_buf > 0 && bufwinid(tree_buf) > 0
    var nodes = getbufvar(tree_buf, 'simpleremote_tree_nodes', [])
    var index = getcurpos(bufwinid(tree_buf))[1] - 1
    var node = index >= 0 && index < len(nodes) ? get(nodes, index, {}) : {}
    if !empty(node)
      default = get(node, 'type', '') ==# 'd' ? node.path : RemoteParent(node.path)
    else
      default = get(s_tree, 'root', s_remote.root)
    endif
  endif
  var directory = input('Upload to remote directory: ', default)
  if empty(directory)
    return
  endif
  UploadToRemote(local, directory)
enddef

def g:SimpleRemoteUploadCommand(local: string, remote_directory: string = '')
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  var source = substitute(fnamemodify(expand(local), ':p'), '[\\/]\+$', '', '')
  var directory = empty(remote_directory)
    ? (empty(s_tree) ? s_remote.root : get(s_tree, 'root', s_remote.root))
    : remote_directory
  UploadToRemote(source, directory)
enddef

def g:SimpleRemoteDownloadCommand(remote: string, local: string = '')
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  var remote_path = NormalizeRemoteTarget(remote)
  var destination = local
  if empty(destination)
    var directory = LocalCopyDirectory()
    destination = (empty(directory) ? getcwd() : directory)
      .. '/' .. fnamemodify(remote_path, ':t')
  endif
  destination = substitute(fnamemodify(expand(destination), ':p'), '[\\/]\+$', '', '')
  if isdirectory(destination)
    destination ..= '/' .. fnamemodify(remote_path, ':t')
  endif
  var force = false
  if filereadable(destination) || isdirectory(destination)
    force = confirm("Replace local path?\n" .. destination, "&Replace\n&Cancel", 2) == 1
    if !force
      return
    endif
  endif
  # Whether the remote path is a directory is only known remotely; ask the
  # agent first so the transfer picks tar or cat accordingly.
  Send('exec', {command: 'test -d ' .. shellescape(remote_path) .. ' && echo d || echo f'},
    (ok, body) => {
      var recursive = ok && trim(body) ==# 'd'
      StartTransfer('download', remote_path, destination,
        {force: force, recursive: recursive})
    })
enddef

def g:SimpleRemoteStatusline(): string
  var latency = get(get(s_remote, 'runtime_probe', {}), 'runtime_ms', '')
  return empty(s_remote) ? '' : printf('%s:%s:%s%s',
    s_remote.kind, s_remote.target, fnamemodify(s_remote.root, ':t'),
    empty(latency) ? '' : '@' .. latency .. 'ms')
enddef

def g:SimpleRemoteComplete(arglead: string, _cmdline: string,
    _cursorpos: number): list<string>
  var values: list<string> = []
  for spec in ConfiguredProfiles() + RecentSpecs() + SshSpecs()
    var value = empty(get(spec, 'name', '')) ? spec.target : spec.name
    if stridx(value, arglead) == 0 && index(values, value) < 0
      add(values, value)
    endif
  endfor
  return values
enddef

def g:VimrcRemoteConnect(kind: string, target: string, root: string)
  Connect(kind, target, root)
enddef

def g:VimrcRemoteDisconnect()
  Disconnect()
enddef

def g:VimrcRemoteOpen(path: string)
  OpenRemote(path)
enddef

def g:VimrcRemoteRead(uri: string)
  ReadRemote(uri)
enddef

def g:VimrcRemoteWrite()
  WriteRemote()
enddef

# Confirm the deferred read of the current buffer.
def g:SimpleRemoteLoadBuffer()
  var buf = bufnr()
  var deferred = get(b:, 'vimrc_remote_deferred', {})
  if type(deferred) != v:t_dict || empty(deferred)
    Error('[VimrcRemote] this buffer has no deferred read')
    return
  endif
  if empty(s_remote) || !IsCurrent(get(deferred, 'generation', -1))
    Error('[VimrcRemote] buffer belongs to an old connection; reopen it first')
    return
  endif
  b:vimrc_remote_deferred = {}
  silent! nunmap <buffer> <CR>
  setlocal modifiable
  echomsg printf('[VimrcRemote] reading %s (%s)…',
    deferred.path, HumanBytes(deferred.size))
  StartRemoteRead(buf, deferred.generation, deferred.path, deferred.uri,
    ReadTimeoutFor(deferred.size))
enddef

def g:VimrcRemoteExec(command: string)
  RemoteExec(command)
enddef

def g:VimrcRemoteFind(query: string)
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  RemoteFind(query)
enddef

def g:VimrcRemotePromptFind()
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  var query = input('remote files: ')
  if !empty(query)
    g:VimrcRemoteFind(query)
  endif
enddef

def g:VimrcRemoteList(path: string = '')
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  RemoteList(path)
enddef

def g:VimrcRemoteHealth()
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  RemoteHealth()
enddef

def g:VimrcRemoteReloadConfig()
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  if !get(s_remote, 'handshake_ready', false)
    Error('[VimrcRemote] connection is not ready')
    return
  endif
  var generation = s_remote.generation
  var buf = bufnr()
  FetchRemoteConfig(generation, (applied) => {
    if IsCurrent(generation)
      if !get(s_remote, 'connection_announced', false)
        # A manual reload can supersede the initial config request.  Whichever
        # request owns the newest epoch must also finish the handshake.
        FinishConnection(generation)
      else
        s_remote.state = 'ready'
        var queued = copy(s_remote.open_queue)
        s_remote.open_queue = []
        for path in queued
          if !IsCurrent(generation) || !IsReady()
            return
          endif
          OpenRemote(path)
          if !IsCurrent(generation) || !IsReady()
            return
          endif
        endfor
      endif
      if !IsCurrent(generation) || !IsReady()
        return
      endif
      if applied
        AnnounceConfigChanged()
      endif
    endif
  })
enddef

def g:VimrcRemoteGit(command: string)
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  RemoteGit(command)
enddef

def g:VimrcRemoteActivateBuffer()
  if bufname() !~# '^remote://'
    return
  endif
  var deferred = get(b:, 'vimrc_remote_deferred', {})
  if type(deferred) == v:t_dict && !empty(deferred)
    MapDeferredLoad(bufnr())
    return
  endif
  var pending = get(b:, 'vimrc_remote_read', {})
  if !empty(pending)
    if !&modified
      pending.tick = b:changedtick
      b:vimrc_remote_read = pending
    endif
    return
  endif
  DetectRemoteFiletype(bufnr())
  SyncRemoteBufferName(bufnr())
  var writepost = get(b:, 'vimrc_remote_writepost_pending', {})
  b:vimrc_remote_writepost_pending = {}
  var info = get(b:, 'vimrc_remote', {})
  if type(writepost) == v:t_dict && !empty(writepost)
    var current_write = IsCurrent(get(writepost, 'generation', -1))
          && get(info, 'generation', -1) == get(writepost, 'generation', -2)
          && b:changedtick == get(writepost, 'tick', -1) && !&modified
    if current_write
          && BufferHasFinalEol(bufnr()) == get(writepost, 'final_eol', false)
      execute 'silent doautocmd <nomodeline> BufWritePost'
    elseif current_write
      # A script may alter EOL/binary options while the buffer is hidden;
      # Vim does not mark that byte-level change modified on its own.
      setlocal modified
    endif
  endif
enddef

command! -nargs=+ VimrcRemoteConnect call g:VimrcRemoteConnect(<f-args>)
command! VimrcRemoteDisconnect call g:VimrcRemoteDisconnect()
command! -nargs=1 VimrcRemoteOpen call g:VimrcRemoteOpen(<q-args>)
command! -nargs=0 VimrcRemoteWrite call g:VimrcRemoteWrite()
command! -nargs=+ VimrcRemoteExec call g:VimrcRemoteExec(<q-args>)
command! -nargs=1 VimrcRemoteFind call g:VimrcRemoteFind(<q-args>)
command! -nargs=? VimrcRemoteList call g:VimrcRemoteList(<q-args>)
command! -nargs=+ VimrcRemoteGit call g:VimrcRemoteGit(<q-args>)
command! VimrcRemoteHealth call g:VimrcRemoteHealth()
command! VimrcRemoteReloadConfig call g:VimrcRemoteReloadConfig()
command! VimrcRemoteStatus echo get(g:, 'vimrc_remote_status', 'disconnected')

def g:VimrcConfigureRemote()
  Disconnect(false)
  augroup vimrc_remote
    autocmd!
    autocmd BufReadCmd remote://* call g:VimrcRemoteRead(expand('<amatch>'))
    autocmd BufWriteCmd remote://* call g:VimrcRemoteWrite()
    autocmd BufEnter remote://* call g:VimrcRemoteActivateBuffer()
    autocmd BufEnter * call g:SimpleRemoteActivateLocalBuffer()
    autocmd VimLeavePre * call g:VimrcRemoteDisconnect()
    autocmd User SimpleStartifySessionLoadPost call g:SimpleRemoteRestoreSessionWorkspace()
    autocmd SessionLoadPost * call g:SimpleRemoteRestoreSessionWorkspace()
  augroup END
enddef

g:VimrcConfigureRemote()
