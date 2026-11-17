vim9script
set nocompatible nomore
const REPO = $SIMPLEREMOTE_TEST_ROOT
const BASE = tempname()
mkdir(BASE, 'p')
writefile(['original'], BASE .. '/victim.txt')
g:simpleremote_use_daemon = 0
g:simpleremote_use_sshfs = 'never'
g:simpleremote_workspace_mode = 'virtual'
g:simpleremote_open_tree_on_connect = 0
g:simpleremote_change_directory = 'none'
g:simpleremote_agent = REPO .. '/bin/simpleremote-agent.sh'
g:simpleremote_confirm_delete = 1
execute 'set runtimepath^=' .. fnameescape(REPO)
runtime plugin/simpleremote.vim

def WaitFor(Condition: func(): bool): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < 4.0
    if Condition()
      return true
    endif
    sleep 10m
  endwhile
  return Condition()
enddef

def Run()
  execute 'SimpleRemoteConnect ssh fixture-target ' .. fnameescape(BASE)
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}), 'root', '') ==# BASE))
  g:VimrcRemoteOpen(BASE .. '/victim.txt')
  assert_true(WaitFor(() => get(get(b:, 'vimrc_remote', {}), 'path', '') ==# BASE .. '/victim.txt'))
  var filebuf = bufnr()
  g:SimpleRemoteTreeToggle()
  assert_true(WaitFor(() => !empty(filter(copy(get(b:, 'simpleremote_tree_nodes', [])), (_, node) => get(node, 'path', '') ==# BASE .. '/victim.txt'))))
  var found = false
  for [index, node] in items(get(b:, 'simpleremote_tree_nodes', []))
    if get(node, 'path', '') ==# BASE .. '/victim.txt'
      cursor(index + 1, 1)
      found = true
      break
    endif
  endfor
  assert_true(found, 'fixture file is visible in the tree')
  g:confirm_timer_ran = false
  timer_start(100, (_) => {
    g:confirm_timer_ran = true
    setbufline(filebuf, 1, 'unsaved during confirmation')
  })
  # The PTY driver waits for the real prompt and presses D after the timer.
  g:SimpleRemoteTreeDelete()
  sleep 100m
  assert_true(g:confirm_timer_ran, 'confirmation allowed asynchronous state changes')
  assert_true(filereadable(BASE .. '/victim.txt'), 'must preserve newly modified remote file')
  assert_equal(['original'], readfile(BASE .. '/victim.txt'))
  assert_equal(['unsaved during confirmation'], getbufline(filebuf, 1, '$'))
enddef

try
  Run()
catch
  add(v:errors, v:exception .. ' @ ' .. v:throwpoint)
finally
  silent! SimpleRemoteDisconnect
  delete(BASE, 'rf')
endtry
writefile(v:errors, $SIMPLEREMOTE_CONFIRM_RESULT)
qall!
