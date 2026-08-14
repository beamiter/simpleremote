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
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}),
    'root', '') ==# BASE), 'runtime-backed workspace did not connect')

  var command = g:SimpleRemoteShellCommand("printf 'runtime-ok\\n'")
  assert_false(empty(command))
  var output: list<string> = []
  var status = -1
  var job = job_start(command, {
    in_io: 'null', out_io: 'pipe', err_io: 'pipe',
    out_mode: 'nl', err_mode: 'nl',
    out_cb: (_, line) => add(output, line),
    exit_cb: (_, code) => {
      status = code
    },
  })
  assert_equal('run', job_status(job))
  assert_true(WaitFor(() => status >= 0), 'runtime exec did not finish')
  assert_equal(0, status)
  assert_equal(['runtime-ok'], output)
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
