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

const PROTOCOL = 'simpleremote/2'

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

def RequestTimedOut(generation: number, key: string)
  if !IsCurrent(generation) || !has_key(s_remote.pending, key)
    return
  endif
  var entry = remove(s_remote.pending, key)
  var Callback = entry.callback
  call(Callback, [false, 'request timed out: ' .. entry.operation])
enddef

def Send(op: string, payload: string, Callback: func): number
  if empty(s_remote) || get(s_remote, 'channel', v:null) == v:null
    Error('[VimrcRemote] not connected')
    call(Callback, [false, 'not connected'])
    return -1
  endif
  if ch_status(s_remote.channel) !=# 'open'
    Error('[VimrcRemote] transport is not writable')
    call(Callback, [false, 'transport is not writable'])
    return -1
  endif

  s_next_id += 1
  var id = s_next_id
  var key = string(id)
  var generation = s_remote.generation
  var timeout = max([0, get(g:, 'vimrc_remote_request_timeout', 15000)])
  var timer = timeout > 0
        ? timer_start(timeout, (_) => RequestTimedOut(generation, key))
        : 0
  s_remote.pending[key] = {
    callback: Callback,
    operation: op,
    timer: timer,
  }
  try
    ch_sendraw(s_remote.channel,
      id .. "\t" .. op .. "\t" .. B64(payload) .. "\n")
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
      call(Callback, [false, 'transport is not writable'])
    endif
    return -1
  endtry
  return id
enddef

def OnLine(generation: number, _channel: any, line: string)
  if !IsCurrent(generation)
    return
  endif
  var parts = split(line, "\t", 1)
  if len(parts) != 3 || !has_key(s_remote.pending, parts[0])
    return
  endif
  var entry = remove(s_remote.pending, parts[0])
  StopRequestTimer(entry)
  var Callback = entry.callback
  call(Callback, [parts[1] ==# 'ok', UnB64(parts[2])])
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
    var Callback = entry.callback
    call(Callback, [false, message])
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
  StopSimpleCC(remote)
  var detail = empty(remote.stderr) ? '' : ': ' .. remote.stderr[-1]
  echomsg printf('[VimrcRemote] connection closed (%d)%s', status, detail)
  Emit('SimpleRemoteDisconnected', {reason: 'transport-exit', code: status})
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

def OnRuntimeProbeExit(generation: number, _job: any, status: number)
  if !IsCurrent(generation)
    return
  endif
  var probe: dict<any> = {status: status}
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
  g:simpleremote_workspace = WorkspaceSnapshot()
  Emit('SimpleRemoteRuntimeReady', copy(g:simpleremote_workspace))
enddef

def StartRuntimeProbe(generation: number)
  var daemon = DaemonPath()
  if empty(daemon) || !IsCurrent(generation)
    return
  endif
  s_remote.runtime_probe_lines = []
  s_remote.runtime_probe_error = ''
  s_remote.runtime_probe = {status: -1}
  s_remote.probe_job = job_start([
    daemon, 'probe', '--kind', s_remote.kind, '--target', s_remote.target,
    '--root', s_remote.root,
  ], {
    in_io: 'null', out_io: 'pipe', err_io: 'pipe', out_mode: 'nl', err_mode: 'nl',
    out_cb: (channel, line) => OnRuntimeProbeLine(generation, channel, line),
    err_cb: (channel, line) => OnRuntimeProbeError(generation, channel, line),
    exit_cb: (job, status) => OnRuntimeProbeExit(generation, job, status),
  })
enddef

def ShellLiteral(value: string): string
  return shellescape(value)
enddef

def DockerAgentCommand(agent: string): string
  if strpart(agent, 0, 2) ==# '~/'
    return 'exec "$HOME"/' .. ShellLiteral(strpart(agent, 2))
  endif
  return 'exec ' .. ShellLiteral(agent)
enddef

def TargetCommand(kind: string, target: string, agent: string): list<string>
  var daemon = DaemonPath()
  if !empty(daemon)
    return [daemon, 'agent', '--kind', kind, '--target', target,
      '--agent', agent]
  endif
  if kind ==# 'docker'
    return ['docker', 'exec', '-i', target, 'sh', '-c',
      DockerAgentCommand(agent)]
  endif
  var script = 'exec ' .. (strpart(agent, 0, 2) ==# '~/'
    ? '"$HOME"/' .. ShellLiteral(strpart(agent, 2))
    : ShellLiteral(agent))
  # OpenSSH joins all arguments after the host into one login-shell command.
  # Quote the complete -c script so that boundary survives that re-serialization.
  return ['ssh', '-T', target, 'sh', '-c', ShellLiteral(script)]
enddef

def StopSimpleCC(remote: dict<any>)
  if get(remote, 'simplecc_started', false) && exists(':SimpleCCStop') == 2
    execute 'silent! SimpleCCStop'
  endif
enddef

def Disconnect(show_message: bool = true)
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
  StopSimpleCC(remote)
  var job = get(remote, 'job', v:null)
  if job != v:null && job_status(job) ==# 'run'
    job_stop(job, 'term')
  endif
  if show_message
    echomsg '[SimpleRemote] disconnected'
  endif
  Emit('SimpleRemoteDisconnected', {reason: 'disconnect'})
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
  RecordRecent()
  echomsg printf('[SimpleRemote] connected %s %s:%s',
    s_remote.kind, s_remote.target, s_remote.root)
  Emit('SimpleRemoteConnected', WorkspaceSnapshot())
  StartRuntimeProbe(generation)

  var queued = copy(s_remote.open_queue)
  s_remote.open_queue = []
  for path in queued
    OpenRemote(path)
  endfor
  if (get(g:, 'simpleremote_open_tree_on_connect', 1)
      || get(get(s_remote, 'options', {}), 'open_tree', false)) && !mounting
    timer_start(0, (_) => OpenWorkspaceTree())
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
  Send('read-config', config_path, (ok, body) => {
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
    var config = UnB64(body)
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

  Disconnect(false)
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
  if job_status(job) ==# 'fail'
    ClearGlobals()
    Error('[VimrcRemote] cannot start transport')
    return
  endif

  s_remote = {
    job: job,
    channel: job_getchannel(job),
    pending: {},
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
    simplecc_started: false,
    simplecc_restart_pending: false,
    options: copy(options),
    local_root: '',
    workspace_mode: 'virtual',
    mount_owned: false,
    mount_job: v:null,
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

  Send('ping', '', (ok, body) => {
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
    FetchRemoteConfig(generation, (_) => FinishConnection(generation))
  })
enddef

def RemoteLines(content: string): list<string>
  var lines = split(content, "\n", 1)
  if content =~# "\n$" && len(lines) > 1 && lines[-1] ==# ''
    remove(lines, -1)
  endif
  return empty(lines) ? [''] : lines
enddef

def DetectRemoteFiletype(buf: number)
  if bufnr() == buf && &filetype ==# ''
    filetype detect
  endif
enddef

def NotifySimpleCCWhenReady(generation: number, attempts: number)
  if !IsCurrent(generation) || attempts <= 0
    return
  endif
  if get(g:, 'simplecc_status', '') ==# 'ready'
    var seen: dict<bool> = {}
    for win in getwininfo()
      var key = string(win.bufnr)
      var info = getbufvar(win.bufnr, 'vimrc_remote', {})
      if !has_key(seen, key)
            && get(info, 'generation', -1) == generation
        seen[key] = true
        win_execute(win.winid, 'silent! call simplecc#OnBufOpen()')
      endif
    endfor
    return
  endif
  timer_start(100, (_) => NotifySimpleCCWhenReady(generation, attempts - 1))
enddef

def RemoteContextBuffer(preferred: number, generation: number): number
  if preferred > 0 && bufname(preferred) =~# '^remote://'
        && get(getbufvar(preferred, 'vimrc_remote', {}),
          'generation', -1) == generation
        && (bufnr() == preferred || bufwinid(preferred) > 0)
    return preferred
  endif
  for win in getwininfo()
    if bufname(win.bufnr) =~# '^remote://'
          && get(getbufvar(win.bufnr, 'vimrc_remote', {}),
            'generation', -1) == generation
      return win.bufnr
    endif
  endfor
  return -1
enddef

def RestartSimpleCC(generation: number, buf: number)
  if !IsCurrent(generation) || exists(':SimpleCCRestart') != 2
    return
  endif
  var context = RemoteContextBuffer(buf, generation)
  if context < 0
    s_remote.simplecc_restart_pending = true
    return
  endif
  var winid = bufwinid(context)
  if bufnr() == context
    execute 'silent! SimpleCCRestart'
  elseif winid > 0
    win_execute(winid, 'silent! SimpleCCRestart')
  else
    s_remote.simplecc_restart_pending = true
    return
  endif
  s_remote.simplecc_started = true
  s_remote.simplecc_restart_pending = false
  NotifySimpleCCWhenReady(generation, 600)
enddef

def MaybeStartSimpleCC(buf: number)
  if !IsReady() || bufname(buf) !~# '^remote://'
    return
  endif
  var info = getbufvar(buf, 'vimrc_remote', {})
  if get(info, 'generation', -1) != s_remote.generation
    return
  endif
  if !get(s_remote, 'simplecc_started', false)
        || get(s_remote, 'simplecc_restart_pending', false)
    RestartSimpleCC(s_remote.generation, buf)
  elseif get(g:, 'simplecc_status', '') ==# 'ready'
    var winid = bufwinid(buf)
    if winid > 0
      win_execute(winid, 'silent! call simplecc#OnBufOpen()')
    endif
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
  var existing = bufnr(uri)
  var was_loaded = existing > 0 && bufloaded(existing)
  if existing > 0 && getbufvar(existing, '&modified')
        && get(getbufvar(existing, 'vimrc_remote', {}), 'generation', -1)
          != s_remote.generation
    Error('[VimrcRemote] refusing to replace modified buffer from an old connection')
    return
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
    remote_path: string, uri: string, ok: bool, body: string)
  if !IsCurrent(generation) || !bufexists(buf)
    return
  endif
  var pending = getbufvar(buf, 'vimrc_remote_read', {})
  if get(pending, 'request_id', -1) != request_id
    return
  endif
  setbufvar(buf, 'vimrc_remote_read', {})
  if !ok
    Error('[VimrcRemote] ' .. body)
    return
  endif
  if getbufvar(buf, 'changedtick', -1) != get(pending, 'tick', -2)
        || getbufvar(buf, '&modified')
    Error('[VimrcRemote] read result ignored because the buffer changed')
    return
  endif

  var content = UnB64(body)
  var lines = RemoteLines(content)
  var old_count = len(getbufline(buf, 1, '$'))
  setbufline(buf, 1, lines)
  if old_count > len(lines)
    deletebufline(buf, len(lines) + 1, old_count)
  endif
  setbufvar(buf, '&endofline', content =~# "\n$")
  setbufvar(buf, '&buftype', 'acwrite')
  setbufvar(buf, '&swapfile', 0)
  setbufvar(buf, 'vimrc_remote', {
    path: remote_path,
    uri: uri,
    generation: generation,
  })
  setbufvar(buf, '&modified', 0)
  MaybeStartSimpleCC(buf)
  DetectRemoteFiletype(buf)
  g:simpleremote_event = {
    type: 'buffer-read',
    bufnr: buf,
    path: remote_path,
    workspace: copy(get(g:, 'simpleremote_workspace', {})),
  }
  silent! doautocmd <nomodeline> User SimpleRemoteBufferRead
enddef

def ReadRemote(uri: string)
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  var buf = bufnr()
  var generation = s_remote.generation
  var remote_path = substitute(uri, '^remote://', '', '')
  var request_id = 0
  request_id = Send('read', remote_path, (ok, body) =>
    ApplyRemoteRead(buf, generation, request_id, remote_path, uri, ok, body))
  if request_id >= 0
    setbufvar(buf, 'vimrc_remote_read', {
      request_id: request_id,
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
  var content = join(getbufline(buf, 1, '$'), "\n")
  if BufferHasFinalEol(buf)
    content ..= "\n"
  endif
  var tick = getbufvar(buf, 'changedtick', -1)
  var final_eol = BufferHasFinalEol(buf)
  Send('write', info.path .. "\t" .. B64(content), (ok, body) =>
    FinishRemoteWrite(buf, generation, tick, final_eol, ok, body))
enddef

def RemoteExec(command: string)
  if empty(s_remote)
    Error('[VimrcRemote] not connected')
    return
  endif
  var root = s_remote.root
  Send('exec', 'cd ' .. shellescape(root) .. ' && ' .. command,
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
  Send('grep', 'cd ' .. shellescape(root) .. ' && ' .. command,
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
  Send('list', remote_path, (ok, body) => {
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
      if fields[1] ==# 'd'
        # Directories are headings, not buffers.  Drill down explicitly with
        # :VimrcRemoteList path instead of opening a guaranteed read error.
        add(items, {text: fields[0] .. '/', valid: 0})
      else
        var child = JoinRemotePath(remote_path, fields[0])
        add(items, {filename: 'remote://' .. child, text: fields[0]})
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
  Send('exec', command, (ok, body) => {
    if ok
      echomsg '[VimrcRemote] ' .. body
    else
      Error('[VimrcRemote] ' .. body)
    endif
  })
enddef

def RemoteGit(command: string)
  var root = s_remote.root
  Send('exec', 'cd ' .. shellescape(root) .. ' && git ' .. command,
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
    if get(g:, 'simpleremote_open_tree_on_connect', 1)
        || get(get(s_remote, 'options', {}), 'open_tree', false)
      timer_start(0, (_) => OpenWorkspaceTree())
    endif
    return
  endif
  PublishWorkspace('virtual')
  echomsg '[SimpleRemote] SSHFS unavailable; using virtual workspace'
  if get(g:, 'simpleremote_open_tree_on_connect', 1)
      || get(get(s_remote, 'options', {}), 'open_tree', false)
    timer_start(0, (_) => OpenWorkspaceTree())
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

def ParseTreeDirectory(path: string, body: string): list<dict<any>>
  var nodes: list<dict<any>> = []
  for line in split(body, '\n')
    var fields = split(line, "\t", 1)
    if len(fields) < 2 || empty(fields[0]) || TreeIgnored(fields[0])
      continue
    endif
    var node = {
      name: fields[0],
      path: JoinRemotePath(path, fields[0]),
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
  Send('exec', command,
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
    metadata: bool, ok: bool, body: string)
  if !IsCurrent(generation) || !bufexists(buf) || empty(s_tree)
        || s_tree.buf != buf || s_tree.epoch != epoch
    return
  endif
  if has_key(s_tree.loading, path)
    remove(s_tree.loading, path)
  endif
  if ok
    if metadata
      s_tree.metadata_supported = 1
    endif
    s_tree.cache[path] = ParseTreeDirectory(path, body)
    if has_key(s_tree.errors, path)
      remove(s_tree.errors, path)
    endif
  elseif metadata && body =~# '^unknown operation:'
    # Older installed agents remain usable; only size/mtime sorting degrades.
    s_tree.metadata_supported = 0
    LoadTreeDirectory(path, true)
    return
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
  Send(metadata ? 'list-meta' : 'list', path,
    (ok, body) => OnTreeList(generation, epoch, buf, path, metadata, ok, body))
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
    '  gd           download file into local SimpleTree',
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
  s_tree.expanded = {s_tree.root: true}
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
    var source_win = get(s_tree, 'source_win', 0)
    if source_win > 0 && win_id2win(source_win) > 0
      win_gotoid(source_win)
    endif
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
  Send('exec', command, (ok, body) => RemoteTreeMutationFinished(
    generation, directory ? 'created folder' : 'created file',
    target, !directory, ok, body))
enddef

def RewriteRemotePath(path: string, source: string, target: string): string
  return path ==# source ? target
    : UnderRoot(path, source) ? target .. strpart(path, len(source)) : path
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
  endfor
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
  Send('exec', command, (ok, body) => {
    if ok && IsCurrent(generation)
      RetargetRemoteBuffers(source, target)
      RewriteRemoteTreeMaps(source, target)
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
  Send('exec', join(['set -e'] + checks + operations, '; '), (ok, body) => {
    if ok && IsCurrent(generation) && mode ==# 'cut'
      for item in get(s_tree_clipboard, 'items', [])
        var moved = JoinRemotePath(destination, fnamemodify(item.path, ':t'))
        RetargetRemoteBuffers(item.path, moved)
        RewriteRemoteTreeMaps(item.path, moved)
      endfor
      s_tree_clipboard = {}
      s_tree.marked = {}
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
  if confirm('Delete remote ' .. label .. '?', "&Delete\n&Cancel", 2) != 1
    return
  endif
  var commands = ['set -e']
  for node in nodes
    add(commands, 'rm -rf ' .. shellescape(node.path))
  endfor
  var generation = s_remote.generation
  Send('exec', join(commands, '; '), (ok, body) => {
    if ok && IsCurrent(generation)
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
  var content = UnB64(body)
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
  Send('read', node.path,
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

def FinishCopyOut(remote_path: string, local_path: string,
    errors: list<string>, status: number)
  if status != 0
    Error(printf('[SimpleRemote] copy failed (%d): %s', status,
      empty(errors) ? remote_path : errors[-1]))
    return
  endif
  var copied = CopyText(local_path)
  echomsg printf('[SimpleRemote] copied %s -> %s%s', remote_path, local_path,
    copied ? '' : ' (path in unnamed register)')
  Emit('SimpleRemoteFileCopied', {
    remote: remote_path,
    local: local_path,
  })
  if exists(':SimpleTreeRefresh') == 2
    silent! execute 'SimpleTreeRefresh'
  endif
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
  if get(node, 'type', '') ==# 'd'
    Error('[SimpleRemote] recursive directory copy is not supported yet')
    return
  endif
  var directory = LocalCopyDirectory()
  var destination = empty(directory) ? ''
    : substitute(directory, '[\\/]\+$', '', '') .. '/' .. fnamemodify(node.path, ':t')
  if empty(destination) || get(g:, 'simpleremote_copy_prompt', 0)
    destination = input('Copy remote file to: ',
      empty(destination) ? expand('~/') .. fnamemodify(node.path, ':t') : destination,
      'file')
  endif
  if empty(destination)
    return
  endif
  destination = fnamemodify(destination, ':p')
  var force = false
  if filereadable(destination) || isdirectory(destination)
    if isdirectory(destination)
      Error('[SimpleRemote] destination is a directory: ' .. destination)
      return
    endif
    force = confirm('Replace local file?\n' .. destination,
      "&Replace\n&Cancel", 2) == 1
    if !force
      return
    endif
  endif
  var daemon = DaemonPath()
  var command: list<string>
  if !empty(daemon)
    command = [daemon, 'download', '--kind', s_remote.kind,
      '--target', s_remote.target, '--root', s_remote.root,
      '--remote', node.path, '--local', destination]
    if !UnderRoot(node.path, s_remote.root)
      add(command, '--allow-outside-root')
    endif
    if force
      add(command, '--force')
    endif
  elseif s_remote.kind ==# 'docker'
    command = ['docker', 'cp', s_remote.target .. ':' .. node.path, destination]
  else
    command = ['scp', s_remote.target .. ':' .. node.path, destination]
  endif
  var errors: list<string> = []
  var remote_path = node.path
  var job = job_start(command, {
    in_io: 'null', out_io: 'null', err_io: 'pipe', err_mode: 'nl',
    err_cb: (_channel, line) => {
      if !empty(line)
        add(errors, line)
      endif
    },
    exit_cb: (_job, status) =>
      FinishCopyOut(remote_path, destination, errors, status),
  })
  if job_status(job) ==# 'fail'
    Error('[SimpleRemote] cannot start file copy')
    return
  endif
  echomsg printf('[SimpleRemote] copying %s -> %s', node.path, destination)
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
  var source_win = win_getid()
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
  var source_win = get(s_tree, 'source_win', 0)
  if source_win > 0 && win_id2win(source_win) > 0
    win_gotoid(source_win)
  else
    wincmd p
    s_tree.source_win = win_getid()
  endif
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

def AgentSourcePath(): string
  return fnamemodify(expand('<sfile>:p'), ':h:h')
    .. '/bin/simpleremote-agent.sh'
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
  if !empty(probe)
    echomsg printf('[SimpleRemote] host=%s python=%s lsp=%s',
      get(probe, 'host', '?'), get(probe, 'python', 'missing'),
      get(probe, 'python_lsp', 'missing'))
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
  if s_remote.kind ==# 'docker'
    command = ['docker', 'exec', '-it', '-w', s_remote.root, s_remote.target,
      'sh']
    if !empty(argument)
      extend(command, ['-lc', argument])
    endif
  else
    var script = 'cd ' .. shellescape(s_remote.root) .. ' && '
    script ..= empty(argument)
      ? 'exec "${SHELL:-sh}" -l'
      : 'exec "${SHELL:-sh}" -lc ' .. shellescape(argument)
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

def g:SimpleRemoteTerminal()
  if !IsReady()
    Error('[SimpleRemote] not connected')
    return
  endif
  if exists(':SimpleTerminalNew') == 2
    execute 'SimpleTerminalNew'
    return
  endif
  var spec = g:SimpleRemoteTerminalSpec()
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

def g:SimpleRemoteOpenWorkspace(workspace: dict<any>)
  var spec = NormalizeSpec(workspace)
  if empty(spec) || get(spec, 'root', '') !~# '^/'
    Error('[SimpleRemote] invalid recent workspace')
    return
  endif
  spec.open_tree = true
  ConnectSpec(spec)
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
  return Send('read', remote_path, (ok, body) => {
    call(Callback, [ok, ok ? UnB64(body) : body])
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
          OpenRemote(path)
        endfor
      endif
      if applied
        s_remote.simplecc_restart_pending = true
        RestartSimpleCC(generation, buf)
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
  var pending = get(b:, 'vimrc_remote_read', {})
  if !empty(pending)
    if !&modified
      pending.tick = b:changedtick
      b:vimrc_remote_read = pending
    endif
    return
  endif
  DetectRemoteFiletype(bufnr())
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
  MaybeStartSimpleCC(bufnr())
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
  augroup END
enddef

g:VimrcConfigureRemote()
