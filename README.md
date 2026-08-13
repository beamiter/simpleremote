# SimpleRemote

SimpleRemote provides native-feeling SSH and Docker workspaces for Vim 9.1.
The Vim9 layer owns the target picker, virtual filesystem buffers, SimpleTree
integration, projections, commands, and public APIs. A small Rust runtime owns
local transport processes and is built by `install.sh`.

```vim
Plug 'beamiter/simpleremote', { 'do': './install.sh' }
```

## Rust runtime

`simpleremote-daemon agent` supervises the persistent remote shell agent.
For SSH targets it uses a private deterministic OpenSSH ControlPath and
ControlPersist, so filesystem RPC, reconnects, and other simple* processes can
reuse authentication and the underlying connection.

`simpleremote-daemon exec` is the shared stdio process boundary. SimpleCC uses
it to run pyright, basedpyright, or another language server in the active
remote workspace. The runtime prepends the project `.venv/bin` when present.
If the binary is unavailable, SimpleRemote and SimpleCC retain their direct
SSH/Docker fallback.

Set `g:simpleremote_use_daemon = 0` to disable the runtime, or set
`g:simpleremote_daemon_path` to a custom build.

See `:help simpleremote` for commands, profiles, workspace projection, and the
integration API.

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
