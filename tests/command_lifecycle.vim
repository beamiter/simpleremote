vim9script

set nocompatible
set nomore

const REPO = $SIMPLEREMOTE_TEST_ROOT
const TARGET = $SIMPLEREMOTE_TEST_TARGET
const BASE = tempname()
mkdir(BASE, 'p')

g:simpleremote_use_daemon = 1
g:simpleremote_daemon_path = REPO .. '/target/debug/simpleremote-daemon'
g:simpleremote_use_sshfs = 'never'
g:simpleremote_workspace_mode = 'virtual'
g:simpleremote_open_tree_on_connect = 0
g:simpleremote_change_directory = 'none'
g:simpleremote_agent = REPO .. '/bin/simpleremote-agent.sh'
execute 'set runtimepath^=' .. fnameescape(REPO)
runtime plugin/simpleremote.vim

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

def Run()
  for daemon in [0, 1]
    g:simpleremote_use_daemon = daemon
    execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
    assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}),
      'root', '') ==# BASE), 'workspace did not connect')
    writefile(['responsive'], BASE .. '/read.txt')
    var replies: list<any> = []
    var id = g:SimpleRemoteExecute('sleep 2', (ok, body) => add(replies, [ok, body]), 100)
    assert_true(id > 0)
    var reads: list<any> = []
    g:SimpleRemoteReadFile('read.txt', (ok, body) => add(reads, [ok, body]))
    assert_true(WaitFor(() => len(reads) == 1, 0.8), 'command blocked file RPC')
    assert_equal([true, "responsive\n"], get(reads, 0, []))
    assert_true(WaitFor(() => len(replies) == 1))
    assert_equal(false, replies[0][0])
    assert_match('timed out.*outcome is unknown', replies[0][1])
    assert_false(g:SimpleRemoteCancel(id))

    replies = []
    id = g:SimpleRemoteExecute('sleep 2', (ok, body) => add(replies, [ok, body]), 0)
    assert_true(g:SimpleRemoteCancel(id))
    assert_false(g:SimpleRemoteCancel(id))
    sleep 150m
    assert_equal(1, len(replies), 'cancel callback duplicated')
    assert_match('canceled.*outcome is unknown', replies[0][1])

    replies = []
    g:SimpleRemoteExecute("printf 'out\\n'; printf 'err\\n' >&2; exit 7",
      (ok, body) => add(replies, [ok, body]))
    assert_true(WaitFor(() => len(replies) == 1))
    assert_equal([false, "out\nerr\n"], replies[0])

    replies = []
    g:SimpleRemoteExecute('head -c 8500000 /dev/zero | tr "\\000" x',
      (ok, body) => add(replies, [ok, body]))
    assert_true(WaitFor(() => len(replies) == 1), 'output limit callback missing')
    assert_match('output limit exceeded.*outcome is unknown', replies[0][1])

    for i in range(5)
      replies = []
      g:SimpleRemoteExecute("printf 'ok\\n'", (ok, body) => add(replies, [ok, body]))
      assert_true(WaitFor(() => len(replies) == 1), 'fast command callback missing')
      assert_equal([true, "ok\n"], replies[0])
    endfor

    replies = []
    var ids: list<number> = []
    for i in range(4)
      add(ids, g:SimpleRemoteExecute('sleep 2', (ok, body) => add(replies, [ok, body]), 0))
    endfor
    assert_equal(-1, g:SimpleRemoteExecute('echo should-not-run',
      (ok, body) => add(replies, [ok, body])))
    assert_equal(1, len(replies))
    assert_match('limit reached.*not started', replies[0][1])
    SimpleRemoteDisconnect
    assert_equal(5, len(replies), 'disconnect must complete every command')
    for pending in ids
      assert_false(g:SimpleRemoteCancel(pending))
    endfor
    sleep 150m
    assert_equal(5, len(replies), 'late completion duplicated disconnect callback')
  endfor
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
