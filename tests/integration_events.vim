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
mkdir(BASE .. '/dest', 'p')
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
# confirm() cannot be answered in silent-ex mode, so the destructive key is
# driven with its confirmation turned off.
g:simpleremote_confirm_delete = 0
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
  autocmd User SimpleRemoteFileUploaded Record('uploaded')
  autocmd User SimpleRemoteFileCopied Record('copied')
  autocmd BufWritePre remote://* g:writepre_seen += 1
augroup END
g:writepre_seen = 0

def Named(name: string): list<dict<any>>
  return filter(copy(events), (_, event) => event.name ==# name)
enddef

# The remote command finishes before its reply reaches Vim, so a file can be
# on disk while its SimpleRemoteFilesChanged event is still in flight: wait
# for the event, never for the filesystem alone.
def LastChanges(): list<any>
  var seen = Named('files')
  return empty(seen) ? [] : seen[-1].changes
enddef

def WaitForChanges(expected: list<any>, message: string)
  assert_true(WaitFor(() => LastChanges() ==# expected),
    message .. ': got ' .. string(LastChanges()))
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
  WaitForChanges([{path: BASE .. '/src/alpha.txt', type: 'deleted'},
    {path: BASE .. '/src/renamed.txt', type: 'created'}],
    'rename announced the wrong changes')

  # Every tree mutation announces itself, not only renames.
  win_gotoid(TreeWin())
  cursor(PathLine(BASE .. '/src'), 1)
  feedkeys("made.txt\<CR>", 't')
  g:SimpleRemoteTreeNewFile()
  WaitForChanges([{path: BASE .. '/src/made.txt', type: 'created'}],
    'tree create announced the wrong change')
  assert_true(filereadable(BASE .. '/src/made.txt'))

  win_gotoid(TreeWin())
  assert_true(WaitFor(() => PathLine(BASE .. '/src/made.txt') > 0),
    'tree did not settle after creating')
  cursor(PathLine(BASE .. '/src/made.txt'), 1)
  g:SimpleRemoteTreeCopy()
  cursor(PathLine(BASE .. '/src'), 1)
  # Pasting into the directory the file already sits in would collide, so the
  # copy goes to the workspace root instead.
  assert_true(g:SimpleRemoteTreeSetRoot(BASE))
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}), 'root', '')
    ==# BASE), 'tree root did not return to the workspace root')
  win_gotoid(TreeWin())
  assert_true(WaitFor(() => PathLine(BASE .. '/src') > 0), 'tree did not reload')
  cursor(1, 1)
  g:SimpleRemoteTreePaste()
  WaitForChanges([{path: BASE .. '/made.txt', type: 'created'}],
    'copy-paste announced the wrong change')
  assert_true(filereadable(BASE .. '/made.txt'))

  win_gotoid(TreeWin())
  assert_true(WaitFor(() => PathLine(BASE .. '/made.txt') > 0),
    'pasted file did not appear')
  cursor(PathLine(BASE .. '/made.txt'), 1)
  g:SimpleRemoteTreeCut()
  cursor(PathLine(BASE .. '/dest'), 1)
  g:SimpleRemoteTreePaste()
  WaitForChanges([{path: BASE .. '/made.txt', type: 'deleted'},
    {path: BASE .. '/dest/made.txt', type: 'created'}],
    'cut-paste announced the wrong changes')
  assert_false(filereadable(BASE .. '/made.txt'))
  assert_true(filereadable(BASE .. '/dest/made.txt'))

  win_gotoid(TreeWin())
  assert_true(WaitFor(() => PathLine(BASE .. '/dest') > 0),
    'tree did not settle after the move')
  cursor(PathLine(BASE .. '/dest'), 1)
  g:SimpleRemoteTreeActivate('edit')
  assert_true(WaitFor(() => PathLine(BASE .. '/dest/made.txt') > 0),
    'moved file did not appear')
  win_gotoid(TreeWin())
  cursor(PathLine(BASE .. '/dest/made.txt'), 1)
  g:SimpleRemoteTreeDelete()
  WaitForChanges([{path: BASE .. '/dest/made.txt', type: 'deleted'}],
    'delete announced the wrong change')
  assert_false(filereadable(BASE .. '/dest/made.txt'))

  # The transfer commands, including the download command's directory probe.
  var drop = BASE .. '/drop'
  mkdir(drop, 'p')
  writefile(['pushed'], drop .. '/pushed.txt')
  g:SimpleRemoteUploadCommand(drop .. '/pushed.txt', BASE .. '/src')
  assert_true(WaitFor(() => filereadable(BASE .. '/src/pushed.txt')),
    ':SimpleRemoteUpload did not land the file')
  assert_equal(['pushed'], readfile(BASE .. '/src/pushed.txt'))
  assert_true(WaitFor(() => !empty(Named('uploaded'))),
    'the upload command did not fire SimpleRemoteFileUploaded')
  assert_equal(BASE .. '/src/pushed.txt', Named('uploaded')[-1].remote)
  g:SimpleRemoteDownloadCommand(BASE .. '/src', drop .. '/srccopy')
  assert_true(WaitFor(() => filereadable(drop .. '/srccopy/pushed.txt')),
    ':SimpleRemoteDownload did not recurse into the remote directory')
  assert_true(WaitFor(() => !empty(Named('copied'))),
    'the download command did not fire SimpleRemoteFileCopied')

  # A file renamed while its buffer is hidden must keep ONE buffer: reopening
  # it by the new name used to make a second one, and the two overwrote each
  # other's saves.
  silent! only!
  set hidden
  writefile(['hide me'], BASE .. '/src/hide.txt')
  g:VimrcRemoteOpen(BASE .. '/src/hide.txt')
  assert_true(WaitFor(() => getline(1) ==# 'hide me'), 'hide.txt did not open')
  var hidden_buf = bufnr()
  g:VimrcRemoteOpen(BASE .. '/src/beta.txt')
  assert_true(WaitFor(() => getline(1) =~# '^beta'), 'second file did not open')
  assert_true(bufexists(hidden_buf) && bufwinid(hidden_buf) < 0,
    'the first buffer should now be hidden')
  var done_rename = false
  g:SimpleRemoteExecute('mv ' .. shellescape(BASE .. '/src/hide.txt')
    .. ' ' .. shellescape(BASE .. '/src/moved.txt'), (_, __) => {
    done_rename = true
  })
  assert_true(WaitFor(() => done_rename), 'the remote move did not finish')
  # Retarget it the way a tree rename does, then reopen under the new name.
  g:SimpleRemoteRetargetBuffers(BASE .. '/src/hide.txt', BASE .. '/src/moved.txt')
  g:VimrcRemoteOpen(BASE .. '/src/moved.txt')
  assert_true(WaitFor(() => getline(1) ==# 'hide me'),
    'the renamed file did not reopen')
  assert_equal(hidden_buf, bufnr(),
    'reopening a renamed file made a second buffer for it')
  assert_equal('remote://' .. BASE .. '/src/moved.txt', bufname(),
    'the reused buffer kept its stale name')
  var on_path = len(filter(getbufinfo(),
    (_, info) => get(getbufvar(info.bufnr, 'vimrc_remote', {}), 'path', '')
      ==# BASE .. '/src/moved.txt'))
  assert_equal(1, on_path, 'more than one buffer holds the same remote path')

  # An API write announces a change too.
  var done = false
  g:SimpleRemoteWriteFile('src/beta.txt', "beta2\n", (_, __) => {
    done = true
  })
  assert_true(WaitFor(() => done), 'api write did not finish')
  WaitForChanges([{path: BASE .. '/src/beta.txt', type: 'changed'}],
    'the API write announced the wrong change')

  # Reloading the remote config announces it when someone listens.
  g:VimrcRemoteReloadConfig()
  assert_true(WaitFor(() => !empty(Named('config'))), 'ConfigChanged did not fire')
  assert_match('events', Named('config')[0].config)

  # A workspace switch reports 'reconnect', not a user disconnect, and it
  # fires Disconnected, Connecting, Connected in that order.
  events = []
  assert_true(g:SimpleRemoteTreeSetRoot(BASE .. '/src'))
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}), 'root', '')
    ==# BASE .. '/src'), 'workspace switch did not finish')
  assert_true(WaitFor(() => !empty(Named('connected'))),
    'the switch never announced the new connection')
  var order = mapnew(events, (_, event) => event.name)
    ->filter((_, name) => index(['disconnected', 'connecting', 'connected'], name) >= 0)
  assert_equal(['disconnected', 'connecting', 'connected'], order)
  assert_equal('reconnect', Named('disconnected')[0].reason)

  # Without a runtime there is no argv-safe transport, and the terminal spec
  # falls back to plain ssh.
  g:simpleremote_use_daemon = 0
  assert_equal([], g:SimpleRemoteExecArgv())
  assert_equal('ssh', g:SimpleRemoteTerminalSpec().command[0])
  g:simpleremote_use_daemon = 1
  assert_equal(g:simpleremote_daemon_path, g:SimpleRemoteTerminalSpec().command[0])

  # Session lines bring the workspace back and re-read its buffers.  Open the
  # file fresh first: the buffer from the start of this test belongs to a
  # generation two re-roots ago.  Leave the tree window before doing it — it
  # is nofile/bufhidden=wipe and must not host a file.
  g:SimpleRemoteTreeClose()
  botright new
  assert_true(filereadable(BASE .. '/src/renamed.txt'),
    'the renamed file vanished during the tree exercises')
  g:VimrcRemoteOpen(BASE .. '/src/renamed.txt')
  # The re-root queued a tree reopen; it can steal the cursor while we wait,
  # so watch the buffer rather than whatever window happens to be current.
  var reopened = bufnr()
  assert_true(WaitFor(() => getbufline(reopened, 1) ==# ['alpha']),
    'could not reopen the renamed file: ' .. bufname(reopened))
  g:SimpleRemoteTreeClose()
  var reopened_win = bufwinid(reopened)
  assert_true(reopened_win > 0, 'the reopened buffer lost its window')
  win_gotoid(reopened_win)

  var lines = g:SimpleRemoteSessionLines()
  assert_equal(1, len(lines))
  assert_match('^let g:simpleremote_session_workspace = ', lines[0])
  SimpleRemoteDisconnect
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'disconnected'))
  assert_equal('disconnect', Named('disconnected')[-1].reason)
  setbufline(reopened, 1, 'stale shell')
  setbufvar(reopened, '&modified', 0)
  # Session files are legacy Vim script; run the line the way :source would.
  execute 'legacy ' .. lines[0]
  doautocmd <nomodeline> User SimpleStartifySessionLoadPost
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}), 'root', '')
    ==# BASE .. '/src' && get(g:, 'simpleremote_status', '') ==# 'ssh:' .. TARGET),
    'session restore did not reconnect')
  assert_true(WaitFor(() => getbufline(reopened, 1) ==# ['alpha']),
    'session restore did not re-read the remote buffer')
  assert_false(exists('g:simpleremote_session_workspace'))

  # RuntimeReady is synchronous whether the probe wins or loses the handshake
  # race.  A listener may disconnect immediately; FinishConnection must not
  # continue into the old open queue afterwards.
  SimpleRemoteDisconnect
  augroup SimpleRemoteRuntimeReadyDisconnect
    autocmd!
    autocmd User SimpleRemoteRuntimeReady ++once SimpleRemoteDisconnect
  augroup END
  v:errmsg = ''
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'disconnected'),
    'RuntimeReady handler did not disconnect reentrantly')
  sleep 50m
  assert_notmatch('E716\|E1065', v:errmsg,
    'connection state was used after RuntimeReady disconnected it')
  augroup SimpleRemoteRuntimeReadyDisconnect
    autocmd!
  augroup END
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
