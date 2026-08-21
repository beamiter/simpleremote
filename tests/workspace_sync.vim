vim9script

set nocompatible
set nomore

const REPO = $SIMPLEREMOTE_TEST_ROOT
const TARGET = $SIMPLEREMOTE_TEST_TARGET
const BASE = tempname()
const CHILD = BASE .. '/child'
const OTHER = CHILD .. '/other'
mkdir(OTHER, 'p')
writefile(['{"workspace": "base"}'], BASE .. '/simplecc.json')
writefile(['{"workspace": "child"}'], CHILD .. '/simplecc.json')

g:simpleremote_use_daemon = 0
g:simpleremote_use_sshfs = 'never'
g:simpleremote_open_tree_on_connect = 0
g:simpleremote_change_directory = 'none'
g:simpleremote_agent = REPO .. '/bin/simpleremote-agent.sh'
g:simpleremote_local_roots = {}
g:simpleremote_local_roots['ssh:' .. TARGET .. ':' .. BASE] = BASE
execute 'set runtimepath^=' .. fnameescape(REPO)
runtime plugin/simpleremote.vim

g:captured_simpletree_root = ''
g:captured_simpletree_reveal = ''
def g:CaptureSimpleTree(root: string)
  g:captured_simpletree_root = root
enddef
def g:CaptureSimpleTreeReveal(path: string)
  g:captured_simpletree_reveal = path
enddef
command! -nargs=? SimpleTree call g:CaptureSimpleTree(<q-args>)
command! -nargs=? SimpleTreeReveal call g:CaptureSimpleTreeReveal(<q-args>)

def WaitForRoot(root: string, timeout: float = 4.0): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < timeout
    var workspace = get(g:, 'simpleremote_workspace', {})
    if get(workspace, 'root', '') ==# root
          && get(g:, 'simpleremote_status', '') ==# 'ssh:' .. TARGET
      return true
    endif
    sleep 10m
  endwhile
  return false
enddef

def WaitForConfig(name: string, timeout: float = 4.0): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < timeout
    if exists('g:vimrc_remote_simplecc_config')
      try
        if get(json_decode(g:vimrc_remote_simplecc_config), 'workspace', '') ==# name
          return true
        endif
      catch
      endtry
    endif
    sleep 10m
  endwhile
  return false
enddef

def WaitFor(Condition: func(): bool, timeout: float = 4.0): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < timeout
    if Condition()
      return true
    endif
    sleep 10m
  endwhile
  return Condition()
enddef

def FireRoot(root: string, old_root: string, source: string)
  g:simpletree_event = {
    root: root,
    path: root,
    old_root: old_root,
    source: source,
  }
  doautocmd <nomodeline> User SimpleTreeRootChanged
enddef

def Run()
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitForRoot(BASE), 'initial workspace did not become ready')
  assert_true(WaitForConfig('base'), 'initial config was not loaded')
  var first_id = g:simpleremote_workspace.id
  assert_equal(BASE, g:simpleremote_workspace.local_root)

  var terminal = g:SimpleRemoteTerminalSpec()
  assert_true(type(terminal) == v:t_dict && !empty(terminal))
  assert_equal(true, terminal.remote)
  assert_equal('', terminal.cwd)
  assert_equal('ssh', terminal.command[0])
  assert_match(BASE, string(terminal.command))
  terminal = g:SimpleRemoteTerminalSpec('printf ready')
  assert_match('printf ready', string(terminal.command))

  # Finder previews use the public asynchronous reader rather than opening a
  # temporary remote buffer for every selected result.
  var read_done = false
  var read_ok = false
  var read_body = ''
  writefile(['finder preview'], BASE .. '/finder.txt')
  assert_true(g:SimpleRemoteReadFile('finder.txt', (ok, body) => {
    read_ok = ok
    read_body = body
    read_done = true
  }) > 0)
  assert_true(WaitForRoot(BASE) && WaitFor(() => read_done),
    'public remote read did not complete')
  assert_true(read_ok)
  assert_equal("finder preview\n", read_body)

  # Remote buffers keep a remote:// name even when the workspace has a local
  # projection.  F3's tree wrapper must translate the active remote file to
  # the projected path and explicitly reveal it after opening SimpleTree.
  g:VimrcRemoteOpen(BASE .. '/finder.txt')
  assert_true(WaitFor(() => get(get(b:, 'vimrc_remote', {}), 'path', '')
    ==# BASE .. '/finder.txt'), 'remote fixture buffer did not finish loading')
  g:SimpleRemoteTreeToggle()
  assert_equal(BASE, g:captured_simpletree_root)
  assert_equal(BASE .. '/finder.txt', g:captured_simpletree_reveal)

  var rejected = false
  assert_equal(-1, g:SimpleRemoteReadFile('/outside-workspace', (_, body) => {
    rejected = body =~# 'outside the active workspace'
  }))
  assert_true(rejected, 'public remote read accepts an outside path')

  rejected = false
  assert_equal(-1, g:SimpleRemoteReadFile('../outside-workspace', (_, body) => {
    rejected = body =~# 'outside the active workspace'
  }))
  assert_true(rejected, 'public remote read accepts parent traversal')

  # A user re-root inside the projection becomes a real remote workspace.  It
  # reconnects with the precise local half of an explicit local map.
  FireRoot(CHILD, BASE, 'here')
  assert_true(WaitForRoot(CHILD), 'SimpleTree child root was not synchronized')
  assert_true(WaitForConfig('child'), 'child workspace config was not loaded')
  assert_notequal(first_id, g:simpleremote_workspace.id)
  assert_equal(CHILD, g:simpleremote_workspace.local_root)
  var child_id = g:simpleremote_workspace.id

  # SimpleRemote's own projection echo must never feed a second reconnect.
  FireRoot(OTHER, CHILD, 'simpleremote')
  sleep 50m
  assert_equal(CHILD, g:simpleremote_workspace.root)
  assert_equal(child_id, g:simpleremote_workspace.id)

  # Root-up carries intent even though the local parent is lexically outside
  # the current projection root.
  FireRoot(BASE, CHILD, 'up')
  assert_true(WaitForRoot(BASE), 'SimpleTree root-up was not synchronized')
  assert_true(WaitForConfig('base'), 'parent workspace config was not restored')
  assert_equal(BASE, g:simpleremote_workspace.local_root)

  # The virtual tree's e/U/C path uses the same workspace-switch primitive.
  assert_true(g:SimpleRemoteTreeSetRoot(CHILD))
  assert_true(WaitForRoot(CHILD), 'remote-tree root did not switch workspace')
  assert_true(WaitForConfig('child'), 'remote-tree workspace config was not loaded')

  # Opening the first queued buffer runs ordinary BufEnter handlers.  If one
  # switches workspace synchronously, the old generation must not continue
  # draining its remaining paths into the replacement connection.
  writefile(['first'], BASE .. '/queued-first.txt')
  writefile(['second'], BASE .. '/queued-second.txt')
  SimpleRemoteDisconnect
  g:queued_switch_target = TARGET
  g:queued_switch_root = CHILD
  def g:SwitchWorkspaceFromQueuedOpen()
    execute 'SimpleRemoteConnect ssh ' .. g:queued_switch_target
      .. ' ' .. fnameescape(g:queued_switch_root)
  enddef
  augroup SimpleRemoteQueuedOpenSwitch
    autocmd!
    autocmd BufEnter remote://* ++once call g:SwitchWorkspaceFromQueuedOpen()
  augroup END
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  g:VimrcRemoteOpen(BASE .. '/queued-first.txt')
  g:VimrcRemoteOpen(BASE .. '/queued-second.txt')
  assert_true(WaitForRoot(CHILD), 'queued open did not switch workspace')
  sleep 100m
  assert_equal(-1, bufnr('remote://' .. BASE .. '/queued-second.txt'),
    'old queued path leaked into the replacement workspace')
  augroup SimpleRemoteQueuedOpenSwitch
    autocmd!
  augroup END
  delfunction g:SwitchWorkspaceFromQueuedOpen
  unlet g:queued_switch_target g:queued_switch_root

  # WorkspaceChanged is emitted synchronously from projection activation,
  # before Connected.  It has the same re-entrant contract as every public
  # event: disconnecting there must stop FinishConnection immediately.
  SimpleRemoteDisconnect
  augroup SimpleRemoteReentrantWorkspaceChanged
    autocmd!
    autocmd User SimpleRemoteWorkspaceChanged ++once SimpleRemoteDisconnect
  augroup END
  v:errmsg = ''
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'disconnected'),
    'WorkspaceChanged handler did not disconnect reentrantly')
  sleep 50m
  assert_notmatch('E716\|E1065', v:errmsg,
    'FinishConnection touched the workspace after WorkspaceChanged replaced it')
  augroup SimpleRemoteReentrantWorkspaceChanged
    autocmd!
  augroup END

  # Connected is a public synchronous event.  A listener may immediately
  # disconnect (or connect another workspace); FinishConnection must not keep
  # using the old generation after that handler returns.
  augroup SimpleRemoteReentrantDisconnect
    autocmd!
    autocmd User SimpleRemoteConnected ++once SimpleRemoteDisconnect
  augroup END
  v:errmsg = ''
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'disconnected'),
    'Connected handler did not disconnect reentrantly')
  sleep 50m
  assert_notmatch('E716\|E1065', v:errmsg,
    'FinishConnection touched the workspace after its Connected handler replaced it')
  augroup SimpleRemoteReentrantDisconnect
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
endtry
if !empty(failure)
  add(v:errors, failure)
endif
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
