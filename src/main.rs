//! `simpleremote-daemon`: the local transport runtime of the SimpleRemote Vim
//! plugin.
//!
//! Vim owns every piece of UI.  This process only assembles SSH/Docker
//! transport commands and, for the persistent agent connection, translates
//! between Vim's JSON lines and the remote agent's base64 line protocol.  It
//! never keeps state across invocations: one process per connection, exec,
//! probe, or transfer.
//!
//! Actions:
//!
//! * `agent` — supervise the persistent remote shell agent; with
//!   `--protocol json` it is a bridge, otherwise it replaces itself with the
//!   transport (historical behaviour)
//! * `exec` — replace itself with the transport running a command in the
//!   workspace root (the shared stdio boundary SimpleCC uses)
//! * `probe` — report the remote environment and round-trip latency
//! * `download` — stream a remote file or directory into a local path
//! * `upload` — stream a local file or directory into a remote path
//! * `capabilities` — print what this build supports, as JSON

mod bridge;
mod transfer;

use std::env;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::Instant;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Bumped when the JSON bridge or the agent bootstrap changes shape.  Vim reads
/// it from `capabilities` and refuses protocol modes it does not understand.
pub const BRIDGE_PROTOCOL: u32 = 1;

/// The heredoc delimiter used to ship the agent script through the transport.
/// The agent must never contain this line; the bootstrap builder checks.
const AGENT_HEREDOC: &str = "SIMPLEREMOTE_AGENT_EOF";

unsafe extern "C" {
    fn geteuid() -> u32;
}

fn effective_uid() -> u32 {
    // SAFETY: geteuid() takes no arguments and has no failure mode on Unix.
    unsafe { geteuid() }
}

#[derive(Default, Debug, Clone)]
pub struct RuntimeArgs {
    pub kind: String,
    pub target: String,
    pub root: String,
    pub agent: String,
    pub agent_source: String,
    pub protocol: String,
    pub remote: String,
    pub local: String,
    pub force: bool,
    pub recursive: bool,
    /// Byte count of a single-file upload, so the remote half can refuse a
    /// stream that was cut short instead of activating a truncated file.
    pub size: u64,
    pub allow_outside_root: bool,
    pub tty: bool,
    pub command: Vec<String>,
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code),
        Err(message) => {
            eprintln!("simpleremote-daemon: {message}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<u8, String> {
    let mut args = env::args().skip(1);
    let action = args.next().unwrap_or_default();
    match action.as_str() {
        "--version" | "version" => {
            println!("simpleremote-daemon {VERSION}");
            return Ok(0);
        }
        "capabilities" => {
            println!("{}", capabilities());
            return Ok(0);
        }
        "agent" | "exec" | "probe" | "download" | "upload" => {}
        _ => {
            return Err(
                "usage: simpleremote-daemon {agent|exec|probe|download|upload|capabilities} [options]"
                    .to_string(),
            );
        }
    }

    let parsed = parse_args(args.collect())?;
    validate(&parsed, &action)?;
    match action.as_str() {
        "download" => return transfer::download(&parsed),
        "upload" => return transfer::upload(&parsed),
        "agent" if parsed.protocol == "json" => return bridge::run(&parsed),
        _ => {}
    }
    let mut command = transport_command(&parsed, &action)?;
    if action == "probe" {
        let started = Instant::now();
        let output = command
            .stdin(Stdio::null())
            .output()
            .map_err(|error| format!("cannot probe {} transport: {error}", parsed.kind))?;
        let mut stdout = io::stdout().lock();
        stdout
            .write_all(&output.stdout)
            .map_err(|error| format!("cannot write probe output: {error}"))?;
        writeln!(stdout, "runtime_ms={}", started.elapsed().as_millis())
            .map_err(|error| format!("cannot write probe latency: {error}"))?;
        writeln!(stdout, "runtime_version={VERSION}")
            .map_err(|error| format!("cannot write probe version: {error}"))?;
        io::stderr()
            .write_all(&output.stderr)
            .map_err(|error| format!("cannot write probe error: {error}"))?;
        return Ok(output.status.code().unwrap_or(1).clamp(0, 255) as u8);
    }
    // The runtime has no work left once the transport command is assembled.
    // Replacing ourselves instead of proxying three pipes preserves the same
    // stdio boundary while making job_stop() reach SSH/Docker directly.  This
    // matters for debounced consumers such as SimpleFinder: cancelling an old
    // grep must cancel its remote process too, not merely its local relay.
    let error = command.exec();
    Err(format!("cannot start {} transport: {error}", parsed.kind))
}

/// One JSON object describing this build.  Vim runs `capabilities` once per
/// binary and caches the answer, so a plugin update that outruns `install.sh`
/// degrades to the historical exec-agent path instead of failing to connect.
fn capabilities() -> String {
    serde_json::json!({
        "version": VERSION,
        "bridge_protocol": BRIDGE_PROTOCOL,
        "actions": ["agent", "exec", "probe", "download", "upload", "capabilities"],
        "agent_protocols": ["exec", "json"],
        "agent_bootstrap": true,
        "recursive_transfer": true,
        "tty": true,
    })
    .to_string()
}

fn parse_args(values: Vec<String>) -> Result<RuntimeArgs, String> {
    let mut parsed = RuntimeArgs::default();
    let mut index = 0;
    while index < values.len() {
        match values[index].as_str() {
            "--" => {
                parsed.command = values[index + 1..].to_vec();
                break;
            }
            "--force" => {
                parsed.force = true;
                index += 1;
                continue;
            }
            "--recursive" => {
                parsed.recursive = true;
                index += 1;
                continue;
            }
            "--allow-outside-root" => {
                parsed.allow_outside_root = true;
                index += 1;
                continue;
            }
            "--tty" => {
                parsed.tty = true;
                index += 1;
                continue;
            }
            _ => {}
        }
        let option = values[index].as_str();
        let value = values
            .get(index + 1)
            .ok_or_else(|| format!("missing value for {option}"))?
            .clone();
        match option {
            "--kind" => parsed.kind = value,
            "--target" => parsed.target = value,
            "--root" => parsed.root = value,
            "--agent" => parsed.agent = value,
            "--agent-source" => parsed.agent_source = value,
            "--protocol" => parsed.protocol = value,
            "--remote" => parsed.remote = value,
            "--local" => parsed.local = value,
            _ => return Err(format!("unknown option: {option}")),
        }
        index += 2;
    }
    Ok(parsed)
}

pub fn validate(args: &RuntimeArgs, action: &str) -> Result<(), String> {
    if args.kind != "ssh" && args.kind != "docker" {
        return Err("--kind must be ssh or docker".to_string());
    }
    if args.target.is_empty() || args.target.starts_with('-') {
        return Err("--target is required".to_string());
    }
    if action == "agent" {
        if args.agent.is_empty() {
            return Err("--agent is required".to_string());
        }
        if !args.protocol.is_empty() && args.protocol != "exec" && args.protocol != "json" {
            return Err("--protocol must be exec or json".to_string());
        }
        if !args.agent_source.is_empty() && !Path::new(&args.agent_source).is_file() {
            return Err(format!(
                "--agent-source is not a readable file: {}",
                args.agent_source
            ));
        }
    }
    if matches!(action, "exec" | "probe" | "download" | "upload") && !args.root.starts_with('/') {
        return Err("--root must be absolute".to_string());
    }
    if action == "exec" && args.command.is_empty() {
        return Err("a command is required after --".to_string());
    }
    if args.tty && action != "exec" {
        return Err("--tty is only meaningful for exec".to_string());
    }
    if action == "download" || action == "upload" {
        let remote = Path::new(&args.remote);
        let root = Path::new(&args.root);
        if !remote.is_absolute()
            || remote
                .components()
                .any(|part| part == Component::ParentDir || part == Component::CurDir)
        {
            return Err("--remote must be an absolute normalized path".to_string());
        }
        if !args.allow_outside_root && !remote.starts_with(root) {
            return Err(
                "--remote must stay inside --root (or pass --allow-outside-root)".to_string(),
            );
        }
        if args.local.is_empty() {
            return Err("--local is required".to_string());
        }
        if remote == Path::new("/") {
            return Err("--remote must name a file or directory, not /".to_string());
        }
    }
    Ok(())
}

/// Wrap `script` in the transport for `args`: `docker exec -i` or an OpenSSH
/// session on the shared ControlMaster socket.  Every action funnels through
/// here so that they all share authentication and the connection.
pub fn transport_command(args: &RuntimeArgs, action: &str) -> Result<Command, String> {
    let script = match action {
        "agent" => agent_script(args)?,
        "probe" => probe_script(&args.root),
        "download" => transfer::download_script(args),
        "upload" => transfer::upload_script(args),
        _ => exec_script(&args.root, &args.command),
    };
    wrap_transport(args, &script, args.tty && action == "exec")
}

/// `wrap_transport` for callers that already have a script.  `tty` asks the
/// transport for a terminal (`ssh -t` / `docker exec -it`), which is what an
/// interactive shell started through `exec --tty` needs; every other action
/// runs without one so stdio stays a clean byte pipe.
pub fn wrap_transport(args: &RuntimeArgs, script: &str, tty: bool) -> Result<Command, String> {
    if args.kind == "docker" {
        let mut command = Command::new("docker");
        command.arg("exec");
        command.arg(if tty { "-it" } else { "-i" });
        command.args([&args.target, "sh", "-c", script]);
        return Ok(command);
    }

    let control_path = control_path(&args.target)?;
    let persist = env::var("SIMPLEREMOTE_CONTROL_PERSIST").unwrap_or_else(|_| "600".to_string());
    let connect_timeout =
        env::var("SIMPLEREMOTE_CONNECT_TIMEOUT").unwrap_or_else(|_| "10".to_string());
    let mut command = Command::new("ssh");
    command
        .arg(if tty { "-t" } else { "-T" })
        .arg("-o")
        .arg("ControlMaster=auto")
        .arg("-o")
        .arg(format!("ControlPersist={persist}"))
        .arg("-o")
        .arg(format!("ControlPath={}", control_path.display()))
        .arg("-o")
        .arg(format!("ConnectTimeout={connect_timeout}"))
        .arg("-o")
        .arg("ConnectionAttempts=1")
        .arg("-o")
        .arg("ServerAliveInterval=15")
        .arg("-o")
        .arg("ServerAliveCountMax=3")
        .arg(&args.target)
        // OpenSSH joins all arguments after the host into one login-shell
        // command line.  Quoting the whole `-c` script keeps its boundary
        // intact through that re-serialization, newlines included.
        .args(["sh", "-c", &shell_quote(script)]);
    Ok(command)
}

/// The remote-side path expression for the agent: `~/x` becomes
/// `"$HOME"/'x'` so the remote shell expands the home directory, everything
/// else is quoted literally.
pub fn agent_path_expression(agent: &str) -> String {
    if let Some(relative) = agent.strip_prefix("~/") {
        format!("\"$HOME\"/{}", shell_quote(relative))
    } else {
        shell_quote(agent)
    }
}

/// The script that starts the agent.  With `--agent-source` it first makes
/// sure the installed agent is byte-identical to the bundled one, so a plugin
/// update — or a first connection — never needs :SimpleRemoteInstallAgent.
pub fn agent_script(args: &RuntimeArgs) -> Result<String, String> {
    if args.agent_source.is_empty() {
        return Ok(format!("exec {}", agent_path_expression(&args.agent)));
    }
    let content = fs::read_to_string(&args.agent_source)
        .map_err(|error| format!("cannot read agent source {}: {error}", args.agent_source))?;
    agent_bootstrap_script(&args.agent, &content)
}

/// Build the self-installing agent launcher.
///
/// The bundled agent travels inside a quoted heredoc, so no byte of it is
/// interpreted by the remote shell.  It is written next to the destination
/// and compared with `cmp`; only a differing (or missing) agent is replaced,
/// atomically, so concurrent connections never observe a half-written file.
/// If the destination directory is not writable but an agent already exists
/// there, that one is used unchanged: an unwritable HOME must not turn into
/// a failed connection.
pub fn agent_bootstrap_script(agent: &str, content: &str) -> Result<String, String> {
    if content.lines().any(|line| line == AGENT_HEREDOC) {
        return Err(format!(
            "agent source contains the heredoc delimiter {AGENT_HEREDOC}"
        ));
    }
    let mut body = content.to_string();
    if !body.ends_with('\n') {
        body.push('\n');
    }
    Ok(format!(
        concat!(
            "dst={dst}; dir=$(dirname -- \"$dst\"); um=$(umask); umask 077; ",
            "mkdir -p -- \"$dir\" 2>/dev/null; ",
            "tmp=$(mktemp \"$dir/.simpleremote-agent.XXXXXX\" 2>/dev/null) || tmp=; ",
            "if [ -n \"$tmp\" ]; then ",
            "cat >\"$tmp\" <<'{eof}'\n{body}{eof}\n",
            "if [ -x \"$dst\" ] && cmp -s -- \"$tmp\" \"$dst\"; then rm -f -- \"$tmp\"; ",
            "elif chmod 700 -- \"$tmp\" && mv -f -- \"$tmp\" \"$dst\"; then :; ",
            "else rm -f -- \"$tmp\"; fi; fi; ",
            // The agent, and everything it runs, must see the login umask —
            // not the private one this installer needed.
            "umask \"$um\"; ",
            "if [ -x \"$dst\" ]; then exec \"$dst\"; fi; ",
            "printf 'simpleremote: cannot install agent at %s\\n' \"$dst\" >&2; exit 126"
        ),
        dst = agent_path_expression(agent),
        eof = AGENT_HEREDOC,
        body = body,
    ))
}

pub fn exec_script(root: &str, command: &[String]) -> String {
    let server = command
        .iter()
        .map(|value| shell_quote(value))
        .collect::<Vec<_>>()
        .join(" ");
    format!("{}; exec {server}", workspace_prelude(root))
}

/// `cd` into the workspace and prepend the project and user tool
/// directories, without sourcing interactive shell files into LSP stdio.
pub fn workspace_prelude(root: &str) -> String {
    format!(
        "cd {} || exit 44; for d in \"$HOME/bin\" \"$HOME/.local/bin\" \"$PWD/env/bin\" \"$PWD/venv/bin\" \"$PWD/.conda/bin\" \"$PWD/.venv/bin\"; do [ -d \"$d\" ] && PATH=\"$d:$PATH\"; done; export PATH",
        shell_quote(root)
    )
}

fn probe_script(root: &str) -> String {
    format!(
        "{}; python=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true); lsp=$(command -v pyright-langserver 2>/dev/null || command -v basedpyright-langserver 2>/dev/null || true); node=$(command -v node 2>/dev/null || true); git=$(command -v git 2>/dev/null || true); rg=$(command -v rg 2>/dev/null || true); tar=$(command -v tar 2>/dev/null || true); printf 'protocol=%s\\nhost=%s\\nroot=%s\\ngit=%s\\npython=%s\\npython_version=%s\\nnode=%s\\npython_lsp=%s\\nrg=%s\\ntar=%s\\nuname=%s\\n' 'simpleremote/runtime/2' \"$(hostname 2>/dev/null || true)\" \"$PWD\" \"$git\" \"$python\" \"$([ -n \"$python\" ] && \"$python\" --version 2>&1 | head -n 1 || true)\" \"$node\" \"$lsp\" \"$rg\" \"$tar\" \"$(uname -sm 2>/dev/null || true)\"",
        workspace_prelude(root)
    )
}

pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn control_path(target: &str) -> Result<PathBuf, String> {
    let uid = effective_uid();
    let root = match env::var_os("XDG_RUNTIME_DIR") {
        Some(value) => {
            let root = PathBuf::from(value);
            if !root.is_absolute() {
                return Err("XDG_RUNTIME_DIR must be an absolute path".to_string());
            }
            validate_private_root(&root, uid)?;
            root
        }
        None => {
            // Resolve the platform temp directory once (macOS commonly spells
            // /tmp through a symlink), then atomically claim a uid-named entry
            // in that sticky directory.  USER is environment input and can be
            // spoofed or collide; the effective uid is the ownership boundary.
            let temporary = fs::canonicalize(env::temp_dir())
                .map_err(|error| format!("cannot resolve the temporary directory: {error}"))?;
            validate_safe_chain(&temporary, uid)?;
            let root = temporary.join(format!("simpleremote-{uid}"));
            ensure_private_dir(&root)?;
            root
        }
    };
    let base = root.join("simpleremote");
    ensure_private_dir(&base)?;
    Ok(base.join(format!("{:016x}.sock", fnv1a(target.as_bytes()))))
}

fn validate_directory(path: &Path) -> Result<fs::Metadata, String> {
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        format!(
            "cannot inspect runtime directory {}: {error}",
            path.display()
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(format!(
            "runtime directory {} is not a real directory",
            path.display()
        ));
    }
    Ok(metadata)
}

/// Every existing component is a real directory, and no non-sticky component
/// lets another user replace entries below it.  A sticky shared temp directory
/// is safe once the child itself is ownership-checked: another uid may create
/// a colliding entry first, but cannot replace one owned by this uid.
fn validate_safe_chain(path: &Path, uid: u32) -> Result<(), String> {
    let system_uid = validate_directory(Path::new("/"))?.uid();
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        let metadata = validate_directory(&current)?;
        let mode = metadata.permissions().mode();
        if metadata.uid() != system_uid && metadata.uid() != uid {
            return Err(format!(
                "runtime path component {} is owned by unexpected uid {}",
                current.display(),
                metadata.uid()
            ));
        }
        if mode & 0o022 != 0 && mode & 0o1000 == 0 {
            return Err(format!(
                "runtime path component {} is writable by other users",
                current.display()
            ));
        }
        // The final private directory is checked more strictly below.  For an
        // ancestor, a different owner is normal (/ and /run are root-owned),
        // provided its mode made replacement impossible.
    }
    Ok(())
}

fn validate_private_root(path: &Path, uid: u32) -> Result<(), String> {
    validate_safe_chain(path, uid)?;
    let metadata = validate_directory(path)?;
    if metadata.uid() != uid {
        return Err(format!(
            "runtime directory {} is owned by uid {}, expected {uid}",
            path.display(),
            metadata.uid()
        ));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(format!(
            "runtime directory {} is accessible by other users",
            path.display()
        ));
    }
    Ok(())
}

fn ensure_private_dir(path: &Path) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("runtime directory {} has no parent", path.display()))?;
    validate_safe_chain(parent, effective_uid())?;

    let mut builder = fs::DirBuilder::new();
    builder.mode(0o700);
    match builder.create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => {
            return Err(format!(
                "cannot create runtime directory {}: {error}",
                path.display()
            ));
        }
    }

    let metadata = validate_directory(path)?;
    let uid = effective_uid();
    if metadata.uid() != uid {
        return Err(format!(
            "runtime directory {} is owned by uid {}, expected {uid}",
            path.display(),
            metadata.uid()
        ));
    }

    // The parent chain is now immutable to other users (or protected by sticky
    // ownership), so the metadata-to-chmod interval cannot be swapped by the
    // cross-user attacker this boundary excludes.
    if metadata.permissions().mode() & 0o7777 != 0o700 {
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| {
            format!(
                "cannot secure runtime directory {}: {error}",
                path.display()
            )
        })?;
    }
    Ok(())
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEMP_NONCE: AtomicU64 = AtomicU64::new(0);

    fn test_path(label: &str) -> PathBuf {
        env::temp_dir().join(format!(
            "simpleremote-{label}-{}-{}",
            std::process::id(),
            TEMP_NONCE.fetch_add(1, Ordering::Relaxed)
        ))
    }

    fn args(kind: &str) -> RuntimeArgs {
        RuntimeArgs {
            kind: kind.into(),
            target: "host".into(),
            root: "/workspace".into(),
            ..RuntimeArgs::default()
        }
    }

    #[test]
    fn exec_uses_project_and_user_environment_paths() {
        let script = exec_script("/tmp/project with space", &["python3".into(), "-V".into()]);
        assert!(script.contains("$PWD/.venv/bin"));
        assert!(script.contains("$HOME/.local/bin"));
        assert!(script.contains("cd '/tmp/project with space'"));
        assert!(script.ends_with("exec 'python3' '-V'"));
    }

    #[test]
    fn probe_requires_an_absolute_root_but_no_command() {
        assert!(validate(&args("ssh"), "probe").is_ok());
        let invalid = RuntimeArgs {
            root: "relative".into(),
            ..args("ssh")
        };
        assert!(validate(&invalid, "probe").is_err());
    }

    #[test]
    fn download_rejects_paths_outside_the_workspace() {
        let outside = RuntimeArgs {
            remote: "/workspace/../secret".into(),
            local: "/tmp/file".into(),
            ..args("ssh")
        };
        assert!(validate(&outside, "download").is_err());
        let allowed = RuntimeArgs {
            allow_outside_root: true,
            remote: "/outside/file".into(),
            ..outside
        };
        assert!(validate(&allowed, "download").is_ok());
    }

    #[test]
    fn upload_refuses_the_filesystem_root_as_destination() {
        let root = RuntimeArgs {
            remote: "/".into(),
            local: "/tmp/file".into(),
            allow_outside_root: true,
            ..args("ssh")
        };
        assert!(validate(&root, "upload").is_err());
        let fine = RuntimeArgs {
            remote: "/workspace/file".into(),
            ..root
        };
        assert!(validate(&fine, "upload").is_ok());
    }

    #[test]
    fn agent_protocol_is_validated() {
        let mut agent = args("ssh");
        agent.agent = "~/agent.sh".into();
        assert!(validate(&agent, "agent").is_ok());
        agent.protocol = "json".into();
        assert!(validate(&agent, "agent").is_ok());
        agent.protocol = "xml".into();
        assert!(validate(&agent, "agent").is_err());
        agent.protocol.clear();
        agent.agent_source = "/definitely/not/here.sh".into();
        assert!(validate(&agent, "agent").is_err());
    }

    #[test]
    fn agent_path_expands_home_only_for_tilde_prefix() {
        assert_eq!(
            agent_path_expression("~/.cache/a.sh"),
            "\"$HOME\"/'.cache/a.sh'"
        );
        assert_eq!(agent_path_expression("/opt/a b.sh"), "'/opt/a b.sh'");
        assert_eq!(agent_path_expression("~user/a.sh"), "'~user/a.sh'");
    }

    #[test]
    fn bootstrap_ships_the_agent_verbatim_and_execs_it() {
        let content = "#!/bin/sh\necho 'it''s' \"$HOME\"\n";
        let script = agent_bootstrap_script("~/.cache/vimrc/agent.sh", content).unwrap();
        assert!(script.starts_with("dst=\"$HOME\"/'.cache/vimrc/agent.sh'; "));
        // The install umask must not leak into the agent's own environment.
        assert!(script.contains("um=$(umask); umask 077; "));
        assert!(script.contains("umask \"$um\"; if [ -x \"$dst\" ]; then exec \"$dst\"; fi"));
        assert!(script.contains(&format!(
            "cat >\"$tmp\" <<'{AGENT_HEREDOC}'\n{content}{AGENT_HEREDOC}\n"
        )));
        assert!(script.contains("cmp -s -- \"$tmp\" \"$dst\""));
        assert!(script.contains("chmod 700 -- \"$tmp\" && mv -f -- \"$tmp\" \"$dst\""));
        assert!(script.contains("if [ -x \"$dst\" ]; then exec \"$dst\"; fi"));
        assert!(script.ends_with("exit 126"));
    }

    #[test]
    fn bootstrap_adds_a_missing_final_newline_and_refuses_the_delimiter() {
        let script = agent_bootstrap_script("/a", "#!/bin/sh").unwrap();
        assert!(script.contains(&format!("#!/bin/sh\n{AGENT_HEREDOC}\n")));
        assert!(agent_bootstrap_script("/a", &format!("x\n{AGENT_HEREDOC}\ny\n")).is_err());
    }

    #[test]
    fn bundled_agent_survives_bootstrap() {
        let source = concat!(env!("CARGO_MANIFEST_DIR"), "/bin/simpleremote-agent.sh");
        let content = fs::read_to_string(source).unwrap();
        assert!(agent_bootstrap_script("~/agent.sh", &content).is_ok());
    }

    #[test]
    fn runtime_directory_is_private_and_never_follows_a_symlink() {
        let directory = test_path("runtime-mode");
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o755)).unwrap();
        ensure_private_dir(&directory).unwrap();
        assert_eq!(
            fs::symlink_metadata(&directory)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );

        let target = test_path("runtime-target");
        let link = test_path("runtime-link");
        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(ensure_private_dir(&link).is_err());
        assert_eq!(
            fs::symlink_metadata(&target).unwrap().permissions().mode() & 0o777,
            0o755,
            "rejecting a runtime symlink must not chmod its target"
        );

        fs::remove_file(link).unwrap();
        fs::remove_dir(target).unwrap();
        fs::remove_dir(directory).unwrap();
    }

    #[test]
    fn runtime_directory_rejects_unsafe_or_symlinked_ancestors() {
        let real_parent = test_path("runtime-real-parent");
        let linked_parent = test_path("runtime-linked-parent");
        fs::create_dir(&real_parent).unwrap();
        std::os::unix::fs::symlink(&real_parent, &linked_parent).unwrap();
        let through_link = linked_parent.join("child");
        assert!(ensure_private_dir(&through_link).is_err());
        assert!(!through_link.exists());

        fs::remove_file(&linked_parent).unwrap();
        fs::remove_dir(&real_parent).unwrap();

        let writable_parent = test_path("runtime-writable-parent");
        fs::create_dir(&writable_parent).unwrap();
        fs::set_permissions(&writable_parent, fs::Permissions::from_mode(0o777)).unwrap();
        let below_writable = writable_parent.join("child");
        assert!(ensure_private_dir(&below_writable).is_err());
        assert!(!below_writable.exists());
        fs::remove_dir(&writable_parent).unwrap();
    }

    #[test]
    fn transport_quotes_the_script_for_ssh_but_not_docker() {
        let mut ssh = args("ssh");
        ssh.command = vec!["true".into()];
        let command = transport_command(&ssh, "exec").unwrap();
        let argv: Vec<String> = command
            .get_args()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert_eq!(argv[0], "-T");
        assert_eq!(argv[argv.len() - 2], "-c");
        assert!(argv[argv.len() - 1].starts_with("'cd '\\''/workspace'\\''"));

        let mut docker = args("docker");
        docker.command = vec!["true".into()];
        let command = transport_command(&docker, "exec").unwrap();
        let argv: Vec<String> = command
            .get_args()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert_eq!(argv[..3], ["exec", "-i", "host"]);
        assert!(argv[argv.len() - 1].starts_with("cd '/workspace'"));
    }

    #[test]
    fn tty_switches_the_transport_flags_for_exec_only() {
        let mut ssh = args("ssh");
        ssh.command = vec!["sh".into()];
        ssh.tty = true;
        let command = transport_command(&ssh, "exec").unwrap();
        assert_eq!(command.get_args().next().unwrap(), "-t");
        let mut docker = args("docker");
        docker.command = vec!["sh".into()];
        docker.tty = true;
        let command = transport_command(&docker, "exec").unwrap();
        let argv: Vec<String> = command
            .get_args()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert_eq!(argv[..2], ["exec", "-it"]);
        let mut probe = args("ssh");
        probe.tty = true;
        assert!(validate(&probe, "probe").is_err());
    }

    #[test]
    fn capabilities_is_json_with_the_bridge_protocol() {
        let parsed: serde_json::Value = serde_json::from_str(&capabilities()).unwrap();
        assert_eq!(parsed["version"], VERSION);
        assert_eq!(parsed["bridge_protocol"], BRIDGE_PROTOCOL);
        assert!(
            parsed["actions"]
                .as_array()
                .unwrap()
                .iter()
                .any(|a| a == "upload")
        );
    }
}
