vim9script

set nomore
g:simpleremote_use_daemon = 0
var root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'source ' .. fnameescape(root .. '/autoload/simpleremote.vim')
defcompile

assert_equal(1, exists('*g:SimpleRemoteConnect'))
assert_equal(1, exists('*g:SimpleRemoteShellCommand'))
assert_equal(1, exists('*g:VimrcConfigureRemote'))
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit 1
endif
qall!
