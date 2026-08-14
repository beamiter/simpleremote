vim9script

set nomore
g:simpleremote_use_daemon = 0
var root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'source ' .. fnameescape(root .. '/autoload/simpleremote.vim')
defcompile

assert_equal(1, exists('*g:SimpleRemoteConnect'))
assert_equal(1, exists('*g:SimpleRemoteShellCommand'))
assert_equal(1, exists('*g:SimpleRemoteProbe'))
assert_equal(1, exists('*g:SimpleRemoteTreeCopyOut'))
assert_equal(1, exists('*g:SimpleRemoteTreeSetRoot'))
assert_equal(1, exists('*g:SimpleRemoteTreeHelp'))
assert_equal(1, exists('*g:SimpleRemoteTreeFind'))
assert_equal(1, exists('*g:SimpleRemoteTreeNewFile'))
assert_equal(1, exists('*g:SimpleRemoteTreeNewFolder'))
assert_equal(1, exists('*g:SimpleRemoteTreeRename'))
assert_equal(1, exists('*g:SimpleRemoteTreeDelete'))
assert_equal(1, exists('*g:SimpleRemoteTreeCopy'))
assert_equal(1, exists('*g:SimpleRemoteTreeCut'))
assert_equal(1, exists('*g:SimpleRemoteTreePaste'))
assert_equal(1, exists('*g:SimpleRemoteTreeMarkToggle'))
assert_equal(1, exists('*g:SimpleRemoteTreeBookmarkToggle'))
assert_equal(1, exists('*g:SimpleRemoteTreeSortCycle'))
assert_equal(1, exists('*g:SimpleRemoteTreeFilter'))
assert_equal(1, exists('*g:VimrcConfigureRemote'))
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit 1
endif
qall!
