vim9script

set nocompatible
set nomore

const REPO = $SIMPLEREMOTE_TEST_ROOT
const TARGET = $SIMPLEREMOTE_TEST_TARGET
const BASE = tempname()
const BOOKMARKS = BASE .. '-bookmarks.json'
mkdir(BASE .. '/dest', 'p')
writefile(['a'], BASE .. '/alpha.txt')
writefile(['nested'], BASE .. '/dest/nested.txt')
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

var sr_script = getscriptinfo({name: 'autoload/simpleremote.vim'})[0]
var sr_sid = sr_script.sid
def Sr(name: string, ...args: list<any>): any
  return call(function(printf('<SNR>%d_%s', sr_sid, name)), args)
enddef

g:simpleremote_large_file_bytes = 'huge'
assert_equal(10485760, Sr('LargeFileLimit'),
  'a non-numeric large-file limit must not reach max()')
g:simpleremote_large_file_bytes = -3
assert_equal(0, Sr('LargeFileLimit'))
unlet g:simpleremote_large_file_bytes

g:simpleremote_request_timeout = v:true
assert_equal(15000, Sr('RequestTimeout'),
  'a boolean request timeout must not reach max()')
unlet g:simpleremote_request_timeout

g:simpleremote_tree_width = 'wide'
assert_equal(38, Sr('TreeWidth'),
  'a string tree width must not reach subtraction')
unlet g:simpleremote_tree_width

g:simpleremote_use_daemon = v:false
assert_equal('', Sr('DaemonPath'),
  'v:false must disable the runtime')
g:simpleremote_use_daemon = 0
g:simpleremote_daemon_path = REPO .. '/lib/simpleremote-daemon'

g:simpleremote_profiles = [{name: 'bad-root', kind: 'ssh', target: 'host', root: ['/tmp']}]
assert_equal('', get(g:SimpleRemoteProfiles()[0], 'root', 'MISSING'),
  'a list root was stored on the spec')
g:simpleremote_profiles = []

g:simpleremote_tree_ignore = 'node_modules'
assert_false(Sr('TreeIgnored', 'node_modules'),
  'a string ignore list must not be walked as characters')
g:simpleremote_tree_ignore = ['.git', '.hg', '.svn', '.venv', 'node_modules', '__pycache__',
  '.mypy_cache', '.pytest_cache', '.ruff_cache']

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

# Genuine agent replies, delayed behind a queued command, prove that buffer
# cleanliness is not a write acknowledgement and old serials cannot clear it.
def WriteAckCases()
  var buffer = bufnr()
  var generation = g:simpleremote_workspace.id
  g:write_ack_posts = 0
  augroup WriteAckFixture
    autocmd!
    autocmd BufWritePost remote://* g:write_ack_posts += 1
  augroup END
  # :write on an already clean buffer still has to wait for its real ACK.
  g:SimpleRemoteExecute('sleep 0.15', (_, _) => 0)
  write
  var clean = g:SimpleRemoteWriteState(buffer)
  assert_equal('pending', clean.status, 'clean explicit write waits for an ACK')
  assert_false(&modified)
  assert_false(Sr('CompleteRemoteTreeRename', BASE .. '/dest/nested.txt',
    BASE .. '/dest/should-not-rename-pending.txt', generation),
    'clean pending writes block the actual remote rename mutation')
  assert_true(filereadable(BASE .. '/dest/nested.txt'))
  assert_false(filereadable(BASE .. '/dest/should-not-rename-pending.txt'))
  Sr('ReadRemote', 'remote://' .. BASE .. '/dest/nested.txt')
  assert_equal({}, get(b:, 'vimrc_remote_read', {}), 'a pending write refuses a new read')
  assert_equal('pending', g:SimpleRemoteWriteState(buffer).status, 'read refusal cannot complete a pending write')
  clean.status = 'fake mutation'
  assert_equal('pending', g:SimpleRemoteWriteState(buffer).status, 'WriteState returns a read-only copy')
  assert_true(WaitFor(() => get(g:SimpleRemoteWriteState(buffer), 'status', '') ==# 'success'))
  assert_equal(b:changedtick, g:SimpleRemoteWriteState(buffer).tick)
  assert_equal(1, g:write_ack_posts, 'successful clean write still emits BufWritePost')

  # Undo can make a pending buffer nominally clean while the remote is about
  # to install the request's newer snapshot. The ACK must mark it stale/dirty.
  setline(1, 'snapshot before undo')
  g:SimpleRemoteExecute('sleep 0.15', (_, _) => 0)
  write
  normal! u
  assert_false(&modified, 'fixture undo returns to the previous saved contents')
  assert_equal('pending', g:SimpleRemoteWriteState(buffer).status)
  assert_true(WaitFor(() => get(g:SimpleRemoteWriteState(buffer), 'status', '') ==# 'stale'))
  assert_true(&modified, 'stale ACK restores modified even when undo cleared it')
  assert_equal(1, g:write_ack_posts, 'stale ACK must not emit BufWritePost')
  assert_equal(['snapshot before undo'], readfile(BASE .. '/dest/nested.txt'))
  setline(1, 'nested')
  write
  assert_true(WaitFor(() => get(g:SimpleRemoteWriteState(buffer), 'status', '') ==# 'success'))

  # EOL flags are byte changes without changedtick; they also cannot certify
  # success for the snapshot currently being written.
  g:SimpleRemoteExecute('sleep 0.15', (_, _) => 0)
  write
  var eol_tick = b:changedtick
  setlocal noendofline nofixendofline nomodified
  assert_equal(eol_tick, b:changedtick)
  assert_true(WaitFor(() => get(g:SimpleRemoteWriteState(buffer), 'status', '') ==# 'stale'))
  assert_true(&modified)
  setlocal endofline fixendofline
  write
  assert_true(WaitFor(() => get(g:SimpleRemoteWriteState(buffer), 'status', '') ==# 'success'))

  # Two in-flight writes: a prior reply must not replace the newer pending
  # serial or mark the latest buffer clean. Exercise the same callback directly
  # before the genuine queued agent replies arrive.
  g:SimpleRemoteExecute('sleep 0.15', (_, _) => 0)
  setline(1, 'first queued snapshot')
  write
  var first = g:SimpleRemoteWriteState(buffer)
  setline(1, 'second queued snapshot')
  write
  var latest = g:SimpleRemoteWriteState(buffer)
  assert_true(latest.serial > first.serial)
  Sr('FinishRemoteWrite', buffer, generation, first.serial, first.tick, first.final_eol, true, 'old reply')
  assert_equal(latest, g:SimpleRemoteWriteState(buffer), 'old ACK leaves newer pending identity untouched')
  assert_true(&modified)
  assert_true(WaitFor(() => get(g:SimpleRemoteWriteState(buffer), 'status', '') ==# 'success'))
  assert_equal(latest.serial, g:SimpleRemoteWriteState(buffer).serial)
  assert_equal(['second queued snapshot'], readfile(BASE .. '/dest/nested.txt'))
  assert_equal(4, g:write_ack_posts, 'superseded ACK does not emit a second BufWritePost')

  # Agent refusal is observable to a caller even if its own write command did
  # not throw. Use a symlink, which the installed agent refuses to replace.
  delete(BASE .. '/dest/nested.txt')
  system('ln -s ' .. shellescape(BASE .. '/alpha.txt') .. ' ' .. shellescape(BASE .. '/dest/nested.txt'))
  setline(1, 'rejected symlink write')
  write
  assert_true(WaitFor(() => get(g:SimpleRemoteWriteState(buffer), 'status', '') ==# 'error'))
  assert_true(&modified)
  assert_match('symbolic link', g:SimpleRemoteWriteState(buffer).message)
  assert_equal(4, g:write_ack_posts, 'failed ACK does not emit BufWritePost')
  delete(BASE .. '/dest/nested.txt')
  writefile(['nested'], BASE .. '/dest/nested.txt')
  setline(1, 'nested')
  write
  assert_true(WaitFor(() => get(g:SimpleRemoteWriteState(buffer), 'status', '') ==# 'success'))

  # A completed ACK belongs to its old snapshot. A successful refresh clears
  # it so a later clean SaveWait cannot mistake the reread's tick for old bytes.
  assert_equal('success', g:SimpleRemoteWriteState(buffer).status)
  Sr('ReadRemote', 'remote://' .. BASE .. '/dest/nested.txt')
  assert_true(WaitFor(() => empty(get(b:, 'vimrc_remote_read', {}))
    && empty(g:SimpleRemoteWriteState(buffer))))
  assert_false(&modified)
  if exists('*g:VimrcSaveWait')
    assert_equal('success', g:VimrcSaveWait(500).status, 'write then reread then clean save/build is valid')
  endif

  # Disconnect fails pending writes immediately. A late callback from that
  # generation must never turn this failed request into a successful save.
  g:SimpleRemoteExecute('sleep 0.2', (_, _) => 0)
  setline(1, 'snapshot interrupted by disconnect')
  write
  var interrupted = g:SimpleRemoteWriteState(buffer)
  SimpleRemoteDisconnect
  assert_equal('error', g:SimpleRemoteWriteState(buffer).status)
  assert_true(&modified)
  Sr('FinishRemoteWrite', buffer, generation, interrupted.serial, interrupted.tick, interrupted.final_eol, true, 'late disconnected reply')
  assert_equal('error', g:SimpleRemoteWriteState(buffer).status, 'disconnected generation cannot report success')
  assert_equal(5, g:write_ack_posts)
  augroup WriteAckFixture
    autocmd!
  augroup END
  setlocal nomodified
  execute 'bwipeout! ' .. buffer
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}), 'root', '') ==# BASE))
  g:VimrcRemoteOpen(BASE .. '/dest/nested.txt')
  assert_true(WaitFor(() => get(get(b:, 'vimrc_remote', {}), 'generation', -1)
    == get(get(g:, 'simpleremote_workspace', {}), 'id', -2)))
enddef

def Run()
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(() => get(get(g:, 'simpleremote_workspace', {}),
    'root', '') ==# BASE), 'virtual workspace did not become ready')
  assert_equal('', Sr('ResolveRemotePath', BASE .. '/../etc/passwd'),
    'a .. walk was not rejected at the workspace boundary')
  var listed = Sr('ParseDirectoryListing', BASE, "..\td\nalpha.txt\tf\n")
  assert_equal(['alpha.txt'], mapnew(listed, (_, e) => e.name),
    'directory listing accepted .. as a child name')
  g:SimpleRemoteTreeToggle()
  assert_true(WaitFor(() => PathLine(BASE .. '/alpha.txt') > 0),
    'virtual tree did not load its root')

  # Opening the virtual tree from a remote file must reveal and select that
  # file, including files below the workspace root.  Close the initial tree so
  # the second toggle follows the same path as F3 from an editor window.
  g:SimpleRemoteTreeToggle()
  g:VimrcRemoteOpen(BASE .. '/dest/nested.txt')
  assert_true(WaitFor(() => get(get(b:, 'vimrc_remote', {}), 'path', '')
    ==# BASE .. '/dest/nested.txt'), 'nested remote buffer did not load')
  WriteAckCases()
  g:SimpleRemoteTreeToggle()
  assert_true(WaitFor(() => PathLine(BASE .. '/dest/nested.txt') > 0),
    'virtual tree did not load the active file parent')
  var reveal_winid = TreeWin()
  var reveal_nodes = TreeNodes()
  var reveal_index = getcurpos(reveal_winid)[1] - 1
  assert_true(reveal_index >= 0 && reveal_index < len(reveal_nodes),
    'virtual tree reveal cursor is outside its node list')
  if reveal_index >= 0 && reveal_index < len(reveal_nodes)
    assert_equal(BASE .. '/dest/nested.txt',
      get(reveal_nodes[reveal_index], 'path', ''),
      'virtual tree did not focus the active remote file')
  endif
  assert_true(g:SimpleRemoteTreeSetRoot(BASE))
  assert_true(WaitFor(() => PathLine(BASE .. '/dest') > 0),
    'virtual tree did not restore the workspace root after reveal')

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
