vim9script

# The contract sibling plugins build on: events and their payloads, the
# public helpers, buffer identity after remote mutations, and the session
# round trip.  Runs through the Rust runtime against the stub ssh fixture.

set nocompatible
set nomore

const REPO = $SIMPLEREMOTE_TEST_ROOT
const TARGET = $SIMPLEREMOTE_TEST_TARGET
const BASE = tempname()
const AGENT_DIR = BASE .. '-agents'
mkdir(BASE .. '/src', 'p')
writefile(['alpha  '], BASE .. '/src/alpha.txt')
writefile(['beta'], BASE .. '/src/beta.txt')
writefile(['{"workspace": "events"}'], BASE .. '/simplecc.json')

g:simpleremote_use_daemon = 1
g:simpleremote_daemon_path = REPO .. '/target/debug/simpleremote-daemon'
g:simpleremote_use_sshfs = 'never'
g:simpleremote_workspace_mode = 'virtual'
g:simpleremote_open_tree_on_connect = 0
g:simpleremote_change_directory = 'none'
g:simpleremote_agent = AGENT_DIR .. '/simpleremote-agent.sh'
g:simpleremote_tree_use_nerdfont = 0
g:simpleremote_tree_root_locked = 0
g:simpleremote_profiles = [
  {name: 'events', kind: 'ssh', target: TARGET, root: BASE},
  {name: 'rootless', kind: 'ssh', target: TARGET},
]
execute 'set runtimepath^=' .. fnameescape(REPO)
runtime plugin/simpleremote.vim

def WaitFor(Condition: func(): bool, timeout: float = 6.0): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < timeout
    if Condition()
      return true
    endif
    sleep 10m
  endwhile
  return Condition()
enddef

def Ready(): bool
  return get(get(g:, 'simpleremote_workspace', {}), 'root', '') ==# BASE
    && get(g:, 'simpleremote_status', '') ==# 'ssh:' .. TARGET
enddef

var events: list<dict<any>> = []
def Record(name: string)
  add(events, extend({name: name}, deepcopy(get(g:, 'simpleremote_event', {}))))
enddef
augroup IntegrationEventsTest
  autocmd!
  autocmd User SimpleRemoteConnecting Record('connecting')
  autocmd User SimpleRemoteConnected Record('connected')
  autocmd User SimpleRemoteDisconnected Record('disconnected')
  autocmd User SimpleRemoteRuntimeReady Record('runtime')
  autocmd User SimpleRemoteBufferRead Record('read')
  autocmd User SimpleRemoteFilesChanged Record('files')
  autocmd User SimpleRemoteConfigChanged Record('config')
  autocmd BufWritePre remote://* g:writepre_seen += 1
augroup END
g:writepre_seen = 0

def Named(name: string): list<dict<any>>
  return filter(copy(events), (_, event) => event.name ==# name)
enddef

def TreeWin(): number
  for window in getwininfo()
    if getbufvar(window.bufnr, '&filetype') ==# 'simpleremotetree'
      return window.winid
    endif
  endfor
  return 0
enddef

def PathLine(path: string): number
  var nodes = getbufvar(winbufnr(TreeWin()), 'simpleremote_tree_nodes', [])
  for index in range(0, len(nodes) - 1)
    if get(nodes[index], 'path', '') ==# path
      return index + 1
    endif
  endfor
  return 0
enddef

def Run()
  # Profiles are exposed for dashboards, root-less ones included.
  var profiles = g:SimpleRemoteProfiles()
  assert_equal(2, len(profiles))
  assert_equal('profile', profiles[0].source)
  assert_equal('', profiles[1].root)

  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(Ready), 'workspace did not become ready')
  assert_true(WaitFor(() => !empty(Named('runtime'))), 'RuntimeReady never fired')
  var connected = Named('connected')
  assert_equal(1, len(connected))
  assert_equal('SimpleRemoteConnected', connected[0].event)
  assert_equal('json', connected[0].protocol)
  # The probe races the handshake; either way the workspace carries it now.
  var probe = get(g:simpleremote_workspace, 'probe', {})
  assert_true(has_key(probe, 'runtime_ms'), 'probe missing runtime_ms: ' .. string(probe))
  assert_equal('simpleremote/runtime/2', get(probe, 'protocol', ''))
  assert_true(!empty(get(probe, 'runtime_version', '')), 'probe lacks runtime_version')

  # Argv prefix for siblings that run their own programs remotely.
  var argv = g:SimpleRemoteExecArgv()
  assert_equal(['exec', '--kind', 'ssh', '--target', TARGET, '--root', BASE, '--'],
    argv[1 :])
  var output: list<string> = []
  var status = -1
  var job = job_start(argv + ['printf', '%s|%s\n', 'a b', '$HOME'], {
    in_io: 'null', out_io: 'pipe', err_io: 'null', out_mode: 'nl',
    out_cb: (_, line) => add(output, line),
    exit_cb: (_, code) => {
      status = code
    },
  })
  assert_true(WaitFor(() => status >= 0), 'exec argv job did not finish')
  assert_equal(0, status)
  assert_equal(['a b|$HOME'], output, 'exec argv must not re-parse arguments')

  # Terminal specs go through the runtime with a tty when it supports one.
  var terminal = g:SimpleRemoteTerminalSpec('true')
  assert_equal(g:simpleremote_daemon_path, terminal.command[0])
  assert_equal(['exec', '--tty', '--kind', 'ssh'], terminal.command[1 : 4])
  assert_equal(true, terminal.remote)

  # BufWritePre reaches remote saves and the read event carries its payload.
  g:VimrcRemoteOpen(BASE .. '/src/alpha.txt')
  assert_true(WaitFor(() => get(get(b:, 'vimrc_remote', {}), 'path', '')
    ==# BASE .. '/src/alpha.txt'), 'remote buffer did not load')
  var reads = Named('read')
  assert_equal(1, len(reads))
  assert_equal('buffer-read', reads[0].type)
  assert_equal(bufnr(), reads[0].bufnr)
  assert_equal(BASE .. '/src/alpha.txt', reads[0].path)
  assert_equal('SimpleRemoteBufferRead', reads[0].event)
  setline(1, 'alpha')
  write
  assert_true(WaitFor(() => readfile(BASE .. '/src/alpha.txt') ==# ['alpha']),
    'remote write did not land')
  assert_equal(1, g:writepre_seen, 'BufWritePre did not fire for the remote save')

  # A tree rename renames the open buffer and announces the change.  Toggled
  # from a remote buffer, the tree opens rooted at that file's directory.
  g:SimpleRemoteTreeToggle()
  assert_true(WaitFor(() => PathLine(BASE .. '/src/alpha.txt') > 0),
    'tree did not reveal the active file')
  win_gotoid(TreeWin())
  cursor(PathLine(BASE .. '/src/alpha.txt'), 1)
  feedkeys("\<C-U>renamed.txt\<CR>", 't')
  g:SimpleRemoteTreeRename()
  assert_true(WaitFor(() => filereadable(BASE .. '/src/renamed.txt')),
    'remote rename did not finish')
  assert_true(WaitFor(() => bufnr('remote://' .. BASE .. '/src/renamed.txt') > 0),
    'renamed buffer kept its old name')
  assert_equal(-1, bufnr('remote://' .. BASE .. '/src/alpha.txt'),
    'stale buffer with the old name survived')
  var files = Named('files')
  assert_true(!empty(files), 'SimpleRemoteFilesChanged did not fire')
  var last = files[-1].changes
  assert_equal([{path: BASE .. '/src/alpha.txt', type: 'deleted'},
    {path: BASE .. '/src/renamed.txt', type: 'created'}], last)

  # An API write announces a change too.
  var done = false
  g:SimpleRemoteWriteFile('src/beta.txt', "beta2\n", (_, __) => {
    done = true
  })
  assert_true(WaitFor(() => done), 'api write did not finish')
  assert_equal({path: BASE .. '/src/beta.txt', type: 'changed'},
    Named('files')[-1].changes[0])

  # Reloading the remote config announces it when someone listens.
  g:VimrcRemoteReloadConfig()
  assert_true(WaitFor(() => !empty(Named('config'))), 'ConfigChanged did not fire')
  assert_match('events', Named('config')[0].config)

  # A workspace switch reports 'reconnect', not a user disconnect.
  assert_true(g:SimpleRemoteTreeSetRoot(BASE .. '/src'))
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}), 'root', '')
    ==# BASE .. '/src'), 'workspace switch did not finish')
  var disconnected = Named('disconnected')
  assert_equal(1, len(disconnected))
  assert_equal('reconnect', disconnected[0].reason)

  # Session lines bring the workspace back and re-read its buffers.
  var lines = g:SimpleRemoteSessionLines()
  assert_equal(1, len(lines))
  assert_match('^let g:simpleremote_session_workspace = ', lines[0])
  SimpleRemoteDisconnect
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'disconnected'))
  assert_equal('disconnect', Named('disconnected')[-1].reason)
  win_gotoid(bufwinid(bufnr('remote://' .. BASE .. '/src/renamed.txt')))
  assert_equal(['alpha'], getline(1, '$'))
  setline(1, 'stale shell')
  setlocal nomodified
  # Session files are legacy Vim script; run the line the way :source would.
  execute 'legacy ' .. lines[0]
  doautocmd <nomodeline> User SimpleStartifySessionLoadPost
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}), 'root', '')
    ==# BASE .. '/src' && get(g:, 'simpleremote_status', '') ==# 'ssh:' .. TARGET),
    'session restore did not reconnect')
  assert_true(WaitFor(() => getline(1) ==# 'alpha'),
    'session restore did not re-read the remote buffer')
  assert_false(exists('g:simpleremote_session_workspace'))
enddef

var failure = ''
try
  Run()
catch
  failure = v:exception .. ' @ ' .. v:throwpoint
finally
  silent! SimpleRemoteDisconnect
  delete(BASE, 'rf')
  delete(AGENT_DIR, 'rf')
endtry
if !empty(failure)
  add(v:errors, failure)
endif
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
