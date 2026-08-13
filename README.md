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
