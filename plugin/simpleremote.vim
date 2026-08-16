vim9script

if exists('g:loaded_simpleremote')
  finish
endif
g:loaded_simpleremote = 1

if v:version < 901
  echoerr '[SimpleRemote] Vim 9.1 or newer is required'
  finish
endif

if !exists('g:simpleremote_profiles')
  g:simpleremote_profiles = []
endif
if !exists('g:simpleremote_workspace_mode')
  g:simpleremote_workspace_mode = 'auto'
endif
if !exists('g:simpleremote_use_sshfs')
  g:simpleremote_use_sshfs = 'auto'
endif
if !exists('g:simpleremote_change_directory')
  g:simpleremote_change_directory = 'tab'
endif
if !exists('g:simpleremote_open_tree_on_connect')
  g:simpleremote_open_tree_on_connect = 1
endif
if !exists('g:simpleremote_sync_tree_root')
  g:simpleremote_sync_tree_root = 1
endif
if !exists('g:simpleremote_tree_width')
  g:simpleremote_tree_width = 40
endif
if !exists('g:simpleremote_tree_use_nerdfont')
  g:simpleremote_tree_use_nerdfont = get(g:, 'simpletree_use_nerdfont', 1)
endif
if !exists('g:simpleremote_tree_show_file_icons')
  g:simpleremote_tree_show_file_icons = 1
endif
if !exists('g:simpleremote_tree_show_git_status')
  g:simpleremote_tree_show_git_status = 1
endif
if !exists('g:simpleremote_tree_show_hidden')
  g:simpleremote_tree_show_hidden = 1
endif
if !exists('g:simpleremote_tree_git_ignore')
  g:simpleremote_tree_git_ignore = 1
endif
if !exists('g:simpleremote_tree_sort')
  g:simpleremote_tree_sort = 'name'
endif
if !exists('g:simpleremote_tree_sort_reverse')
  g:simpleremote_tree_sort_reverse = 0
endif
if !exists('g:simpleremote_tree_root_locked')
  g:simpleremote_tree_root_locked = get(g:, 'simpletree_root_locked', 1)
endif
if !exists('g:simpleremote_tree_mark_symbol')
  g:simpleremote_tree_mark_symbol = get(g:, 'simpletree_mark_symbol', '✓')
endif
if !exists('g:simpleremote_tree_bookmark_symbol')
  g:simpleremote_tree_bookmark_symbol = get(g:, 'simpletree_bookmark_symbol', '★')
endif
if !exists('g:simpleremote_tree_bookmarks_file')
  g:simpleremote_tree_bookmarks_file = ''
endif
if !exists('g:simpleremote_tree_ignore')
  g:simpleremote_tree_ignore = [
    '.git', '.hg', '.svn', '.venv', 'node_modules', '__pycache__',
    '.mypy_cache', '.pytest_cache', '.ruff_cache',
  ]
endif
if !exists('g:simpleremote_default_root')
  g:simpleremote_default_root = '/'
endif
if !exists('g:simpleremote_use_daemon')
  g:simpleremote_use_daemon = 1
endif
if !exists('g:simpleremote_copy_destination')
  g:simpleremote_copy_destination = ''
endif
if !exists('g:simpleremote_confirm_delete')
  g:simpleremote_confirm_delete = 1
endif
if !exists('g:simpleremote_copy_prompt')
  g:simpleremote_copy_prompt = 0
endif
if !exists('g:simpleremote_clipboard_max_bytes')
  g:simpleremote_clipboard_max_bytes = 1024 * 1024
endif

const PLUGIN_ROOT = fnamemodify(expand('<sfile>:p'), ':h:h')
if !exists('g:simpleremote_daemon_path')
  g:simpleremote_daemon_path = PLUGIN_ROOT .. '/lib/simpleremote-daemon'
endif
execute 'source ' .. fnameescape(PLUGIN_ROOT .. '/autoload/simpleremote.vim')

command! -nargs=0 SimpleRemote call g:SimpleRemoteUI()
command! -nargs=* -complete=customlist,SimpleRemoteComplete SimpleRemoteConnect call g:SimpleRemoteConnectCommand(<f-args>)
command! -nargs=0 SimpleRemoteDisconnect call g:VimrcRemoteDisconnect()
command! -nargs=0 SimpleRemoteReconnect call g:SimpleRemoteReconnect()
command! -nargs=0 SimpleRemoteHosts call g:SimpleRemoteUI()
command! -nargs=0 SimpleRemoteContainers call g:SimpleRemoteUI()
command! -nargs=? SimpleRemoteWorkspace call g:SimpleRemoteWorkspace(<q-args>)
command! -nargs=0 SimpleRemoteTree call g:SimpleRemoteTreeToggle()
command! -nargs=0 SimpleRemoteTreeReveal call g:SimpleRemoteTreeReveal()
command! -nargs=1 SimpleRemoteOpen call g:VimrcRemoteOpen(<q-args>)
command! -nargs=+ SimpleRemoteExec call g:VimrcRemoteExec(<q-args>)
command! -nargs=1 SimpleRemoteFind call g:VimrcRemoteFind(<q-args>)
command! -nargs=+ SimpleRemoteGit call g:VimrcRemoteGit(<q-args>)
command! -nargs=* SimpleRemoteTerminal call g:SimpleRemoteTerminal(<q-args>)
command! -nargs=0 SimpleRemoteInstallAgent call g:SimpleRemoteInstallAgent()
command! -nargs=0 SimpleRemoteHealth call g:VimrcRemoteHealth()
command! -nargs=0 SimpleRemoteReloadConfig call g:VimrcRemoteReloadConfig()
command! -nargs=0 SimpleRemoteStatus call g:SimpleRemoteShowStatus()
command! -nargs=0 SimpleRemoteProbe call g:SimpleRemoteProbe()
command! -nargs=0 SimpleRemoteCopy call g:SimpleRemoteTreeCopyOut()
command! -nargs=0 SimpleRemoteCopyContents call g:SimpleRemoteTreeCopyContents()
command! -nargs=1 SimpleRemoteTreeRoot call g:SimpleRemoteTreeSetRoot(<q-args>)
command! -nargs=+ -complete=file SimpleRemoteUpload call g:SimpleRemoteUploadCommand(<f-args>)
command! -nargs=+ -complete=file SimpleRemoteDownload call g:SimpleRemoteDownloadCommand(<f-args>)
command! -nargs=0 SimpleRemoteTreeFind call g:SimpleRemoteTreeFind(1, 1)

nnoremap <silent> <Plug>(simpleremote-open) <Cmd>SimpleRemote<CR>
nnoremap <silent> <Plug>(simpleremote-connect) <Cmd>SimpleRemoteConnect<CR>
nnoremap <silent> <Plug>(simpleremote-disconnect) <Cmd>SimpleRemoteDisconnect<CR>
nnoremap <silent> <Plug>(simpleremote-reconnect) <Cmd>SimpleRemoteReconnect<CR>
nnoremap <silent> <Plug>(simpleremote-tree-toggle) <Cmd>SimpleRemoteTree<CR>
nnoremap <silent> <Plug>(simpleremote-status) <Cmd>SimpleRemoteStatus<CR>

augroup SimpleRemoteTreeIntegration
  autocmd!
  autocmd User SimpleTreeRootChanged call g:SimpleRemoteOnSimpleTreeRootChanged()
  # SimpleTree asks a provider to reveal buffers with a foreign scheme.
  autocmd User SimpleTreeRevealForeign call g:SimpleRemoteTreeReveal()
  # `gu` in a SimpleTree buffer uploads its selected node into the remote
  # workspace; SimpleTree leaves the key free and keeps buffer maps set on
  # FileType.
  autocmd FileType simpletree nnoremap <buffer> <nowait> <silent> gu <Cmd>call g:SimpleRemoteUploadFromTree()<CR>
augroup END
