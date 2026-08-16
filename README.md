# SimpleRemote

SimpleRemote provides native-feeling SSH and Docker workspaces for Vim 9.1.
The Vim9 layer owns the target picker, virtual filesystem buffers, SimpleTree
integration, projections, commands, and public APIs. A small Rust runtime owns
local transport processes and is built by `install.sh`.

```vim
Plug 'beamiter/simpleremote', { 'do': './install.sh' }
```

## Rust runtime

`simpleremote-daemon agent --protocol json` supervises the persistent remote
shell agent as a **JSON bridge**: Vim exchanges one JSON object per line and
the runtime performs every base64 step of the agent's line protocol
in-process. Before this, Vim spawned `base64` twice per request; a directory
listing, a file read, a save or a SimpleFinder preview no longer costs a
process. Payloads that are not valid UTF-8 travel base64-encoded so latin-1
and binary files round-trip byte for byte. Without the runtime, Vim still
drives ssh/docker and base64 itself; an older runtime is detected through
`simpleremote-daemon capabilities` and used the way it always was.

The **remote agent installs itself**. Every connection ships the bundled
`bin/simpleremote-agent.sh` inside the launch command, compares it with the
installed copy and atomically replaces the copy only when it differs — a fresh
host or a plugin update never needs `:SimpleRemoteInstallAgent`.

For SSH targets the runtime uses a private deterministic OpenSSH ControlPath
and ControlPersist, so the agent, probes, transfers, language servers,
searches and terminals share one authenticated connection.

`simpleremote-daemon exec` is the shared stdio process boundary. SimpleCC uses
it to run pyright, basedpyright, or another language server in the active
remote workspace; SimpleFinder runs its searches through it; SimpleGit runs
`git` through it. The runtime replaces itself with the transport for exec
jobs, so stopping a Vim job stops the remote process too, and it prepends the
project `.venv/bin`, `~/.local/bin` and friends. `exec --tty` allocates a
terminal, which `:SimpleRemoteTerminal` and SimpleTerminal use so remote
shells share the connection and the same PATH prelude.

`simpleremote-daemon download` and `upload` stream a file — or, with
`--recursive`, a directory through `tar` — across the boundary, staged beside
the destination and activated by rename; uploads refuse an existing
destination unless `--force`. Without the runtime, `scp`/`docker cp` do the
same job.

Set `g:simpleremote_use_daemon = 0` to disable the runtime, or set
`g:simpleremote_daemon_path` to a custom build.

## Integration API for simple\* plugins

`make suite-check` loads the installed siblings alongside SimpleRemote,
connects a fixture-backed workspace and asserts that each one reacts — the
one test that exercises the contract instead of a stub of it. It is separate
from `make check` because that gate must pass in a checkout containing this
plugin alone.

Everything a sibling needs is a global function or a `User` event, all
feature-detected, none required. `:help simpleremote-suite` maps who uses
what; the short list:

- `g:SimpleRemoteShellCommand(script)` / `g:SimpleRemoteExecArgv()` — run a
  shell script or an argv in the workspace root through the runtime.
- `g:SimpleRemoteExecute(cmd, Cb)`, `g:SimpleRemoteReadFile(path, Cb)`,
  `g:SimpleRemoteWriteFile(path, content, Cb)`,
  `g:SimpleRemoteListDirectory(path, Cb)` — asynchronous remote filesystem
  operations over the persistent connection.
- `g:SimpleRemoteDownload(remote, local, opts, Cb)` /
  `g:SimpleRemoteUpload(local, remote, opts, Cb)` — file or directory
  transfers.
- `g:SimpleRemoteTerminalSpec([cmd])`, `g:SimpleRemoteStatusline()`,
  `g:SimpleRemoteRecentWorkspaces()`, `g:SimpleRemoteProfiles()`,
  `g:SimpleRemoteOpenWorkspace(ws)`, `g:SimpleRemoteSessionLines()`.
- Events: `SimpleRemoteConnecting/Connected/WorkspaceChanged/RuntimeReady/
  Disconnected` for the connection, `SimpleRemoteBufferRead` for buffers,
  `SimpleRemoteFilesChanged` for tree/upload/API mutations,
  `SimpleRemoteConfigChanged` for a reloaded remote `simplecc.json`,
  `SimpleRemoteFileCopied/FileUploaded` for transfers.

See `:help simpleremote` for commands, profiles, workspace projection, and the
integration API.

## SimpleFinder integration

SimpleFinder detects the active remote workspace automatically.  In a virtual
workspace its file, grep, interactive grep, word/visual grep, symbol, and Git
file sources execute through SimpleRemote's shared SSH/Docker transport;
results open as `remote://` buffers and previews are read asynchronously over
the persistent agent.  A mounted or explicitly mapped workspace keeps using
SimpleFinder's native local daemon against the projected local root.
Workspace changes refresh a live finder panel, while `:SimpleFinderRoot`
switches the real SimpleRemote workspace in the other direction. Set
`g:simplefinder_remote = 0` to opt out.

## SimpleTerminal integration

`g:SimpleRemoteTerminalSpec([command])` exposes an argv-based SSH/Docker
terminal specification for the active workspace. SimpleTerminal consumes it
so local and remote shells share one popup/session UI. When SimpleTerminal is
installed, `:SimpleRemoteTerminal` delegates to that UI automatically.

## Runtime probe and remote environment

`simpleremote-daemon probe` reuses the SSH ControlMaster connection to report
the remote host, project root, Git, Python, Node, Python LSP, and round-trip
latency. SimpleRemote runs it asynchronously after connection, publishes it as
the `probe` member of `g:simpleremote_workspace`, and shows it through
`:SimpleRemoteStatus`. Use `:SimpleRemoteProbe` to refresh the snapshot.

Remote commands automatically prepend project `.venv`, `.conda`, `venv`, and
`env` tool directories plus `$HOME/.local/bin` and `$HOME/bin`. This makes uv,
project Python environments, and user-installed language servers available to
non-login SSH sessions without sourcing interactive shell files into LSP stdio.

## SimpleTree-compatible virtual tree

The virtual remote tree now follows almost the complete SimpleTree key
vocabulary. Filesystem actions execute on the remote target:

- `c` / `x` collect the current node or marked nodes for remote copy/cut;
  `p` pastes them into the selected directory. Directories are recursive and
  every destination is collision-checked before the batch starts.
- `a` / `n` create a file, `A` / `N` create a directory, `r` renames, and `D`
  deletes after confirmation. Delete refuses the tree root and any subtree
  containing an unsaved remote buffer.
- `<Space>` marks a node or a Visual range, `gm` marks its visible siblings,
  and `gM` clears all marks. Copy, cut, and delete consume the marked set.
- `m` toggles a persistent target-scoped bookmark, `'` lists bookmarks, and
  `]b` / `[b` cycle through visible bookmarks.

`gd` is the cross-boundary download: it streams the selected remote file — or
directory — through the Rust runtime into `simpletree#ExternalDropDirectory()`
(or prompts when no local tree exists), staged beside the destination and
atomically activated; SimpleTree then reveals the new file. `gu` is the
upload in the other direction: SimpleTree's selected node (or a prompted
local path) lands in the selected remote directory. `y` copies the file name,
`Y` copies the absolute remote path, and `gy` copies remote text file
contents subject to `g:simpleremote_clipboard_max_bytes` (1 MiB by default).

All copied text and resulting local paths use `simpleclipboard#CopyText()` when
available. Successful downloads emit `User SimpleRemoteFileCopied` with
`g:simpleremote_event.remote` and `.local`, then refresh SimpleTree. Set
`g:simpleremote_copy_destination` for a fixed local drop directory or
`g:simpleremote_copy_prompt = 1` to confirm every download destination.

The remote tree also shares SimpleTree's root-navigation vocabulary: `e` uses
the selected directory, `U` moves to its parent up to `/`, and `C` accepts any
absolute remote directory. These explicit root changes now switch the real
SimpleRemote workspace, so projection discovery, the working directory,
remote config, and SimpleCC all follow the tree. The same synchronization runs
when a projected SimpleTree emits `SimpleTreeRootChanged`; SimpleRemote tags
its own `simpletree#ExternalSetRoot()` echo to avoid a reconnect loop. Set
`g:simpleremote_sync_tree_root = 0` to retain detached browsing. `.` restores a
view-only reveal to the current workspace root.
Press `?` in the virtual remote tree for a complete key reference; the
statusline keeps a visible `[? keys]` hint.

The virtual tree also mirrors SimpleTree navigation and view state: `o` and
arrow keys, `S/V/t`, Ctrl split keys, `P` preview, `R` refresh, `H` hidden
files, `I` gitignore filtering, `s` sort mode, `gs` reverse sort, `F` loaded
node filtering, `z` collapse all, `f` reveal active file, `/` find, and
`]f`/`[f` match cycling. `L` locks root-changing actions. The statusline shows
all active modes. Size and modification-time sorting use the bundled agent's
`list-meta` capability; update an older installed agent with
`:SimpleRemoteInstallAgent`. The only SimpleTree key in the documented panel
without a virtual equivalent is `gx`, because a remote path has no reliable
local system-default application.
