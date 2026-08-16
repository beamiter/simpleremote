vim9script

# Force-compile every :def in autoload/, then check the global surface the
# rest of the configuration binds to.
#
# Vim9 compiles def bodies lazily, so a type error in a branch no test reaches
# stays invisible until a user gets there.  The obvious spelling of the check
# does not perform it:
#
#     source autoload/simpleremote.vim
#     defcompile
#
# :defcompile compiles the functions of the script it is *executed in*, which
# is this file — the sourced script's 253 defs belong to another script context
# and were never touched.  Verified: a `var x: number = 'a string'` planted in
# g:VimrcRemoteHealth() passed this gate with exit 0.  What did fail, when the
# error happened to sit in a function reached while sourcing, was the assert
# block below — so the gate looked alive while covering only the hot path.
#
# Sourcing a copy with a trailing :defcompile puts the compile inside the
# script that owns the functions.  The copy is sourced instead of the original
# rather than as well as it: these are `def g:Name()` globals, and defining
# them twice is an error.
set nomore
g:simpleremote_use_daemon = 0
var root = fnamemodify(expand('<sfile>:p'), ':h:h')
var source = root .. '/autoload/simpleremote.vim'
var compiled = tempname() .. '.vim'
writefile(readfile(source) + ['defcompile'], compiled)
try
  execute 'source ' .. fnameescape(compiled)
catch
  # An uncaught exception here would leave -es Vim waiting on stdin instead of
  # exiting, so CI would hang rather than fail.  Record it and fall through to
  # the cquit below.
  add(v:errors, 'defcompile failed: ' .. v:exception .. ' @ ' .. v:throwpoint)
finally
  delete(compiled)
endtry

assert_equal(1, exists('*g:SimpleRemoteConnect'))
assert_equal(1, exists('*g:SimpleRemoteShellCommand'))
assert_equal(1, exists('*g:SimpleRemoteProbe'))
assert_equal(1, exists('*g:SimpleRemoteTreeCopyOut'))
assert_equal(1, exists('*g:SimpleRemoteTreeUpload'))
assert_equal(1, exists('*g:SimpleRemoteUpload'))
assert_equal(1, exists('*g:SimpleRemoteDownload'))
assert_equal(1, exists('*g:SimpleRemoteExecute'))
assert_equal(1, exists('*g:SimpleRemoteWriteFile'))
assert_equal(1, exists('*g:SimpleRemoteListDirectory'))
assert_equal(1, exists('*g:SimpleRemoteRuntimeCapabilities'))
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
