vim9script

set nocompatible
set nomore

const REPO = $SIMPLEREMOTE_TEST_ROOT
const TARGET = $SIMPLEREMOTE_TEST_TARGET
const BASE = tempname()
const BOOKMARKS = BASE .. '-bookmarks.json'
mkdir(BASE .. '/dest', 'p')
writefile(['a'], BASE .. '/alpha.txt')
writefile(['bbbbbbbb'], BASE .. '/beta.log')
writefile(['ignored'], BASE .. '/ignored.log')
writefile(['{"workspace": "virtual-tree"}'], BASE .. '/simplecc.json')
if executable('git')
  system('git -C ' .. shellescape(BASE) .. ' init -q')
  writefile(['ignored.log'], BASE .. '/.gitignore')
endif

g:simpleremote_use_daemon = 0
g:simpleremote_use_sshfs = 'never'
g:simpleremote_workspace_mode = 'virtual'
g:simpleremote_open_tree_on_connect = 0
g:simpleremote_change_directory = 'none'
g:simpleremote_agent = REPO .. '/bin/simpleremote-agent.sh'
g:simpleremote_tree_use_nerdfont = 0
g:simpleremote_tree_root_locked = 0
g:simpleremote_tree_bookmarks_file = BOOKMARKS
execute 'set runtimepath^=' .. fnameescape(REPO)
runtime plugin/simpleremote.vim

def TreeWin(): number
  for window in getwininfo()
    if getbufvar(window.bufnr, '&filetype') ==# 'simpleremotetree'
      return window.winid
    endif
  endfor
  return 0
enddef

def TreeBuf(): number
  var winid = TreeWin()
  return winid > 0 ? winbufnr(winid) : -1
enddef

def TreeNodes(): list<any>
  return getbufvar(TreeBuf(), 'simpleremote_tree_nodes', [])
enddef

def PathLine(path: string): number
  var nodes = TreeNodes()
  for index in range(0, len(nodes) - 1)
    if get(nodes[index], 'path', '') ==# path
      return index + 1
    endif
  endfor
  return 0
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

def Select(path: string)
  var winid = TreeWin()
  assert_true(winid > 0, 'remote tree window is missing')
  win_gotoid(winid)
  var lnum = PathLine(path)
  assert_true(lnum > 0, 'remote tree node is missing: ' .. path
    .. ' nodes=' .. string(TreeNodes()))
  if lnum > 0
    cursor(lnum, 1)
  endif
enddef

def MetadataReady(): bool
  var lnum = PathLine(BASE .. '/renamed.txt')
  return lnum > 0 && get(TreeNodes()[lnum - 1], 'size', -1) >= 0
enddef

def Run()
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}),
    'root', '') ==# BASE), 'virtual workspace did not become ready')
  g:SimpleRemoteTreeToggle()
  assert_true(WaitFor(() => PathLine(BASE .. '/alpha.txt') > 0),
    'virtual tree did not load its root')

  var winid = TreeWin()
  win_gotoid(winid)
  assert_match('SimpleRemoteTreeRename', maparg('r', 'n'))
  assert_match('SimpleRemoteTreeRefresh', maparg('R', 'n'))
  assert_match('SimpleRemoteTreeSortCycle', maparg('s', 'n'))
  assert_match("SimpleRemoteTreeActivate('split')", maparg('S', 'n'))
  assert_match('SimpleRemoteTreeCopy', maparg('c', 'n'))
  assert_match('SimpleRemoteTreeCopyOut', maparg('gd', 'n'))
  assert_match('SimpleRemoteTreeMarkToggle', maparg('<Space>', 'n'))
  assert_match('SimpleRemoteTreeDelete', maparg('D', 'n'))
  assert_match('SimpleRemoteTreeFilter', maparg('F', 'n'))
  assert_match('SimpleRemoteTreeToggleGitIgnore', maparg('I', 'n'))
  assert_match('SimpleRemoteTreeToggleRootLock', maparg('L', 'n'))
  assert_match('SimpleRemoteTreeBookmarkToggle', maparg('m', 'n'))

  # Create a remote file and folder in the selected directory.
  Select(BASE .. '/dest')
  feedkeys("created.txt\<CR>", 't')
  g:SimpleRemoteTreeNewFile()
  assert_true(WaitFor(() => filereadable(BASE .. '/dest/created.txt')),
    'new remote file was not created')
  win_gotoid(winid)
  assert_true(WaitFor(() => PathLine(BASE .. '/dest') > 0),
    'tree did not settle after creating a file')
  Select(BASE .. '/dest')
  feedkeys("folder\<CR>", 't')
  g:SimpleRemoteTreeNewFolder()
  assert_true(WaitFor(() => isdirectory(BASE .. '/dest/folder')),
    'new remote folder was not created')
  assert_true(WaitFor(() => PathLine(BASE .. '/alpha.txt') > 0),
    'tree did not settle after creating nodes')

  # Rename, copy, and cut/paste all operate on the remote target.
  Select(BASE .. '/alpha.txt')
  feedkeys("\<C-U>renamed.txt\<CR>", 't')
  g:SimpleRemoteTreeRename()
  assert_true(WaitFor(() => filereadable(BASE .. '/renamed.txt')),
    'remote rename did not finish')
  assert_false(filereadable(BASE .. '/alpha.txt'))
  assert_true(WaitFor(() => PathLine(BASE .. '/renamed.txt') > 0),
    'renamed node did not return to the tree')

  Select(BASE .. '/renamed.txt')
  g:SimpleRemoteTreeCopy()
  Select(BASE .. '/dest')
  g:SimpleRemoteTreePaste()
  assert_true(WaitFor(() => filereadable(BASE .. '/dest/renamed.txt')),
    'remote copy/paste did not finish')
  assert_true(WaitFor(() => PathLine(BASE .. '/beta.log') > 0),
    'tree did not settle after copy/paste')

  Select(BASE .. '/beta.log')
  g:SimpleRemoteTreeCut()
  Select(BASE .. '/dest')
  g:SimpleRemoteTreePaste()
  assert_true(WaitFor(() => filereadable(BASE .. '/dest/beta.log')),
    'remote cut/paste did not finish')
  assert_false(filereadable(BASE .. '/beta.log'))

  # Marks feed batch copy and are rendered/statused like SimpleTree.
  writefile(['one'], BASE .. '/batch-one.txt')
  writefile(['two'], BASE .. '/batch-two.txt')
  g:SimpleRemoteTreeRefresh()
  assert_true(WaitFor(() => PathLine(BASE .. '/batch-two.txt') > 0))
  Select(BASE .. '/batch-one.txt')
  g:SimpleRemoteTreeMarkToggle()
  Select(BASE .. '/batch-two.txt')
  g:SimpleRemoteTreeMarkToggle()
  assert_match('marked:2', g:SimpleRemoteTreeStatusline())
  g:SimpleRemoteTreeCopy()
  Select(BASE .. '/dest')
  g:SimpleRemoteTreePaste()
  assert_true(WaitFor(() => filereadable(BASE .. '/dest/batch-one.txt')
    && filereadable(BASE .. '/dest/batch-two.txt')),
    'marked batch copy did not finish')
  g:SimpleRemoteTreeMarkClear()
  assert_true(WaitFor(() => PathLine(BASE .. '/renamed.txt') > 0),
    'tree did not settle after batch copy')

  # Filtering, bookmarks, root locking, and metadata sorting are live UI state.
  Select(BASE .. '/renamed.txt')
  g:SimpleRemoteTreeBookmarkToggle()
  assert_match('★', getbufline(TreeBuf(), PathLine(BASE .. '/renamed.txt'))[0])
  g:SimpleRemoteTreeToggleRootLock()
  assert_match('locked', g:SimpleRemoteTreeStatusline())
  g:SimpleRemoteTreeToggleRootLock()

  feedkeys("renamed\<CR>", 't')
  g:SimpleRemoteTreeFilter()
  assert_true(PathLine(BASE .. '/renamed.txt') > 0)
  assert_equal(0, PathLine(BASE .. '/batch-one.txt'))
  feedkeys("\<C-U>\<CR>", 't')
  g:SimpleRemoteTreeFilter()

  g:SimpleRemoteTreeSortCycle() # extension
  g:SimpleRemoteTreeSortCycle() # mtime; requests list-meta
  g:SimpleRemoteTreeSortCycle() # size; supersedes the mtime request
  assert_true(WaitFor(MetadataReady),
    'metadata sorting did not receive list-meta fields')
  g:SimpleRemoteTreeSortReverse()
  assert_match('sort:size:rev', g:SimpleRemoteTreeStatusline())

  if executable('git')
    assert_true(WaitFor(() => PathLine(BASE .. '/ignored.log') == 0),
      'gitignored file was not filtered')
    g:SimpleRemoteTreeToggleGitIgnore()
    assert_true(PathLine(BASE .. '/ignored.log') > 0,
      'gitignore toggle did not reveal ignored file: '
        .. g:SimpleRemoteTreeStatusline() .. ' ' .. string(TreeNodes()))
  endif
enddef

var failure = ''
try
  Run()
catch
  failure = v:exception .. ' @ ' .. v:throwpoint
finally
  silent! SimpleRemoteDisconnect
  delete(BASE, 'rf')
  delete(BOOKMARKS)
endtry
if !empty(failure)
  add(v:errors, failure)
endif
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
