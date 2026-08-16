vim9script

# Cross-plugin integration.
#
# Every other test in this repository — and every test in the sibling plugins —
# stubs the other side away: SimpleRemote's tests fake SimpleTree, and the
# siblings' tests fake SimpleRemote, because each plugin has to build and pass
# on its own.  That leaves exactly one thing untested anywhere: the real
# contract meeting its real consumers.  This is that test.
#
# It is deliberately NOT part of `make check`, which must pass in a checkout
# that contains this plugin and nothing else (CI runs exactly that).  Run it
# with `make suite-check` in a real ~/.vim/plugged where the siblings live;
# every sibling it cannot find is skipped and reported, so it stays useful as
# the suite grows.

set nocompatible
set nomore

const REPO = $SIMPLEREMOTE_TEST_ROOT
const TARGET = $SIMPLEREMOTE_TEST_TARGET
const SUITE = fnamemodify(REPO, ':h')
const BASE = tempname()
const AGENT = BASE .. '-agent.sh'
mkdir(BASE .. '/src', 'p')
writefile(['root = true', '[*]', 'indent_style = space', 'indent_size = 3'],
  BASE .. '/.editorconfig')
writefile(['fn main() {', '    let x = 1;', '}'], BASE .. '/src/main.rs')

def Available(plugin: string): bool
  return isdirectory(SUITE .. '/' .. plugin)
enddef

var skipped: list<string> = []
var exercised: list<string> = []

g:simpleremote_use_daemon = 1
g:simpleremote_daemon_path = REPO .. '/target/debug/simpleremote-daemon'
g:simpleremote_use_sshfs = 'never'
g:simpleremote_workspace_mode = 'virtual'
g:simpleremote_open_tree_on_connect = 0
g:simpleremote_change_directory = 'none'
g:simpleremote_agent = AGENT

# The siblings' own daemons are not what this checks; keep them idle so a
# missing binary cannot turn into a failure here.
g:simpletreesitter_auto_enable_filetypes = []
g:simpleminimap_auto_open = 0
g:simpleline_git_enabled = 0
g:simplecc_auto_start = 0
g:simplemarkdown_auto_open = 0
g:simpleremote_profiles = [
  {name: 'suite', kind: 'ssh', target: $SIMPLEREMOTE_TEST_TARGET, root: '/srv/suite'},
]

const SIBLINGS = ['simpleline', 'simpleeditorconfig', 'simpletreesitter',
  'simpleminimap', 'simplewhichkey', 'simpleterminal', 'simplecc', 'simplegit',
  'simplefinder', 'simpletree', 'simplestartify', 'simplemarkdown',
  'simpleclipboard']
execute 'set runtimepath^=' .. fnameescape(REPO)
for plugin in SIBLINGS
  if Available(plugin)
    execute 'set runtimepath^=' .. fnameescape(SUITE .. '/' .. plugin)
  else
    add(skipped, plugin)
  endif
endfor
filetype plugin indent on
syntax enable
runtime plugin/simpleremote.vim
for plugin in SIBLINGS
  if Available(plugin)
    execute 'runtime plugin/' .. plugin .. '.vim'
  endif
endfor

def WaitFor(Condition: func(): bool, timeout: float = 8.0): bool
  var started = reltime()
  while reltimefloat(reltime(started)) < timeout
    if Condition()
      return true
    endif
    sleep 10m
  endwhile
  return Condition()
enddef

def TreeWindow(): number
  for window in getwininfo()
    if getbufvar(window.bufnr, '&filetype') ==# 'simpleremotetree'
      return window.winid
    endif
  endfor
  return 0
enddef

def Run()
  execute 'SimpleRemoteConnect ssh ' .. TARGET .. ' ' .. fnameescape(BASE)
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'ssh:' .. TARGET),
    'the workspace never connected')

  # The statusline advertises the workspace as soon as it is up.
  if Available('simpleline')
    var line = simpleline#ActiveStatusline()
    assert_true(line =~# 'ssh:' .. TARGET,
      'SimpleLine does not show the workspace: ' .. line)
  endif

  g:VimrcRemoteOpen(BASE .. '/src/main.rs')
  assert_true(WaitFor(() => getline(1) ==# 'fn main() {'),
    'the remote buffer never loaded')
  var remote_buf = bufnr()
  assert_equal('acwrite', &buftype)
  assert_equal('rust', &filetype,
    'the remote buffer never got its filetype, so no FileType consumer ran')

  # A remote buffer is a file, not a URI, to the statusline.
  if Available('simpleline')
    var line = simpleline#ActiveStatusline()
    assert_true(line !~# 'remote://',
      'SimpleLine still prints the remote:// URI: ' .. line)
    assert_true(line =~# 'main\.rs',
      'SimpleLine lost the file name: ' .. line)
    add(exercised, 'simpleline: workspace segment and remote filename')
  endif

  # The remote .editorconfig is walked over the agent and applied.
  if Available('simpleeditorconfig')
    assert_true(WaitFor(() => &shiftwidth == 3),
      'the remote .editorconfig was not applied: sw=' .. &shiftwidth
        .. ' sources=' .. string(get(b:, 'simpleeditorconfig_sources', [])))
    assert_true(&expandtab, 'the remote .editorconfig did not set expandtab')
    assert_true(index(get(b:, 'simpleeditorconfig_sources', []),
      BASE .. '/.editorconfig') >= 0,
      'the applied config did not come from the remote workspace root')
    add(exercised, 'simpleeditorconfig: remote .editorconfig walk')
  endif

  # The minimap treats the acwrite buffer as a source.
  if Available('simpleminimap')
    silent SimpleMinimapOpen
    assert_true(WaitFor(() => {
      for session in values(get(simpleminimap#DebugStatus(), 'sessions', {}))
        if get(session, 'source_bufnr', -1) == remote_buf
          return true
        endif
      endfor
      return false
    }), 'the minimap did not adopt the remote buffer as its source')
    silent SimpleMinimapClose
    add(exercised, 'simpleminimap: remote buffer as source')
  endif

  # The remote shell goes through the runtime, so it shares the connection.
  if Available('simpleterminal')
    var spec = g:SimpleRemoteTerminalSpec()
    assert_equal(true, spec.remote)
    assert_equal(g:simpleremote_daemon_path, spec.command[0],
      'the terminal spec does not go through the runtime: ' .. string(spec.command))
    add(exercised, 'simpleterminal: workspace shell spec')
  endif

  # The tree's multi-key mappings are named for the which-key panel.
  g:SimpleRemoteTreeToggle()
  assert_true(WaitFor(() => TreeWindow() > 0), 'the remote tree did not open')
  win_gotoid(TreeWindow())
  if Available('simplewhichkey')
    var described = get(get(b:, 'simplewhichkey_descriptions', {}), 'n', {})
    assert_equal('download to local tree', get(described, 'gd', ''),
      'the tree did not describe gd to SimpleWhichKey')
    assert_equal('upload local file here', get(described, 'gu', ''),
      'the tree did not describe gu to SimpleWhichKey')
    add(exercised, 'simplewhichkey: remote tree key descriptions')
  endif
  g:SimpleRemoteTreeClose()

  # SimpleCC spells a remote buffer's URI with the path on the remote host,
  # which is what makes a language server running there understand it.
  if Available('simplecc')
    assert_equal('file://' .. BASE .. '/src/main.rs',
      simplecc#PathToUri('remote://' .. BASE .. '/src/main.rs'),
      'SimpleCC does not map a remote:// buffer to a remote file URI')
    assert_equal('remote://' .. BASE .. '/src/main.rs',
      simplecc#UriToPath('file://' .. BASE .. '/src/main.rs'),
      'SimpleCC does not map a remote file URI back to a remote:// buffer')
    add(exercised, 'simplecc: remote URI mapping')
  endif

  # SimpleGit sees a remote buffer as a file rather than a special buffer.
  if Available('simplegit')
    var status = simplegit#StatusDict(remote_buf)
    assert_equal(v:t_dict, type(status),
      'SimpleGit refused to look at the remote buffer')
    add(exercised, 'simplegit: remote buffer is a file')
  endif

  # SimpleClipboard resolves the path on the remote host rather than a local
  # guess.  :SimpleCopyPath goes to the system clipboard and never to a
  # register — for local files too — so what it resolved is read back through
  # its own report instead.
  if Available('simpleclipboard')
    var clipboard_window = bufwinid(remote_buf)
    assert_true(clipboard_window > 0, 'the remote buffer lost its window')
    win_gotoid(clipboard_window)
    silent! simpleclipboard#CopyPathToClipboard(true)
    assert_equal(strlen(BASE .. '/src/main.rs'),
      get(simpleclipboard#LastCopy(), 'bytes', -1),
      'SimpleClipboard did not copy the absolute remote path')
    silent! simpleclipboard#CopyPathToClipboard(false)
    assert_equal(strlen('src/main.rs'),
      get(simpleclipboard#LastCopy(), 'bytes', -1),
      'SimpleClipboard did not copy the workspace-relative remote path')
    add(exercised, 'simpleclipboard: remote path resolution')
  endif

  # SimpleFinder searches the workspace rather than the local directory.  Its
  # panel is a popup driven by typeahead, which a silent-ex Vim cannot feed;
  # the cross-plugin promise is the root it resolves and the transport it
  # would search through, and both are plain function calls.
  if Available('simplefinder')
    # Health() renders into its own scratch buffer rather than echoing.
    silent! simplefinder#Health()
    var health = join(getline(1, '$'), "\n")
    assert_true(health =~# 'remote workspace: ssh:' .. TARGET .. ':' .. BASE,
      'the finder did not detect the workspace: ' .. health)
    assert_true(health =~# 'remote search: through the SimpleRemote transport',
      'the finder would not search through the workspace transport: ' .. health)
    silent! bwipeout!
    var argv = g:SimpleRemoteShellCommand('printf hello')
    assert_true(!empty(argv) && argv[0] ==# g:simpleremote_daemon_path,
      'that transport is not the runtime: ' .. string(argv))
    add(exercised, 'simplefinder: workspace detection and transport')
  endif

  # SimpleStartify offers the configured profile even with no history.
  if Available('simplestartify')
    var entries = g:SimpleRemoteProfiles()
    assert_true(!empty(entries), 'no profiles to offer the dashboard')
    assert_equal('suite', entries[0].name)
    add(exercised, 'simplestartify: profile source')
  endif

  # SimpleMarkdown treats a remote markdown buffer as markdown.
  if Available('simplemarkdown')
    writefile(['# Remote', '', 'body'], BASE .. '/src/doc.md')
    g:VimrcRemoteOpen(BASE .. '/src/doc.md')
    assert_true(WaitFor(() => getline(1) ==# '# Remote'),
      'the remote markdown buffer never loaded')
    assert_equal('markdown', &filetype)
    silent! SimpleMarkdownToc
    assert_true(WaitFor(() => !empty(getqflist()) || !empty(getloclist(0))
      || &filetype ==# 'markdown'),
      'SimpleMarkdown refused the remote markdown buffer')
    add(exercised, 'simplemarkdown: remote markdown buffer')
  endif

  # SimpleTree exports the selection SimpleRemote uploads from.
  if Available('simpletree')
    assert_equal(v:t_string, type(simpletree#ExternalSelectedPath()),
      'SimpleTree does not export a selected path')
    assert_equal(v:t_list, type(simpletree#ExternalMarkedPaths()),
      'SimpleTree does not export its marked set')
    add(exercised, 'simpletree: selection exports')
  endif

  # A remote save reaches every BufWritePre consumer, which is what makes
  # trimming, format-on-save and friends work on a remote file at all.
  g:suite_writepre = 0
  augroup SuiteIntegrationWrite
    autocmd!
    autocmd BufWritePre remote://* g:suite_writepre += 1
  augroup END
  var save_window = bufwinid(remote_buf)
  if save_window <= 0
    # The markdown detour reused this window; bring the buffer back.
    execute 'buffer ' .. remote_buf
    save_window = win_getid()
  endif
  assert_true(save_window > 0, 'the remote buffer lost its window')
  win_gotoid(save_window)
  assert_equal(remote_buf, bufnr(), 'the save window holds the wrong buffer')
  setline(2, '    let x = 2;')
  write
  assert_true(WaitFor(() => readfile(BASE .. '/src/main.rs')[1] ==# '    let x = 2;'),
    'the remote save did not land')
  assert_equal(1, g:suite_writepre, 'BufWritePre did not reach the siblings')

  # Everything survives the workspace going away.
  SimpleRemoteDisconnect
  assert_true(WaitFor(() => get(g:, 'simpleremote_status', '') ==# 'disconnected'))
  if Available('simpleline')
    var line = simpleline#ActiveStatusline()
    assert_true(line !~# 'ssh:' .. TARGET,
      'SimpleLine still advertises a dead workspace: ' .. line)
    assert_true(!empty(line), 'SimpleLine broke after the disconnect')
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
  delete(AGENT)
endtry
if !empty(failure)
  add(v:errors, failure)
endif
var report = ['suite integration: ' .. len(exercised) .. ' integrations exercised']
  + mapnew(exercised, (_, item) => '  ok   ' .. item)
  + mapnew(skipped, (_, item) => '  skip ' .. item .. ' (not installed)')
writefile(report, '/dev/stderr')
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
