use std::env;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::thread;
use std::time::Instant;

const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Default)]
struct RuntimeArgs {
    kind: String,
    target: String,
    root: String,
    agent: String,
    command: Vec<String>,
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
    if action == "--version" || action == "version" {
        println!("simpleremote-daemon {VERSION}");
        return Ok(0);
    }
    if action != "agent" && action != "exec" && action != "probe" {
        return Err("usage: simpleremote-daemon {agent|exec|probe} [options]".to_string());
    }

    let parsed = parse_args(args.collect())?;
    validate(&parsed, &action)?;
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
        io::stderr()
            .write_all(&output.stderr)
            .map_err(|error| format!("cannot write probe error: {error}"))?;
        return Ok(output.status.code().unwrap_or(1).clamp(0, 255) as u8);
    }
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let child = command
        .spawn()
        .map_err(|error| format!("cannot start {} transport: {error}", parsed.kind))?;
    proxy(child)
}

fn parse_args(values: Vec<String>) -> Result<RuntimeArgs, String> {
    let mut parsed = RuntimeArgs::default();
    let mut index = 0;
    while index < values.len() {
        if values[index] == "--" {
            parsed.command = values[index + 1..].to_vec();
            break;
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
            _ => return Err(format!("unknown option: {option}")),
        }
        index += 2;
    }
    Ok(parsed)
}

fn validate(args: &RuntimeArgs, action: &str) -> Result<(), String> {
    if args.kind != "ssh" && args.kind != "docker" {
        return Err("--kind must be ssh or docker".to_string());
    }
    if args.target.is_empty() || args.target.starts_with('-') {
        return Err("--target is required".to_string());
    }
    if action == "agent" && args.agent.is_empty() {
        return Err("--agent is required".to_string());
    }
    if (action == "exec" || action == "probe") && !args.root.starts_with('/') {
        return Err("--root must be absolute".to_string());
    }
    if action == "exec" && args.command.is_empty() {
        return Err("a command is required after --".to_string());
    }
    Ok(())
}

fn transport_command(args: &RuntimeArgs, action: &str) -> Result<Command, String> {
    let script = match action {
        "agent" => agent_script(&args.agent),
        "probe" => probe_script(&args.root),
        _ => exec_script(&args.root, &args.command),
    };
    if args.kind == "docker" {
        let mut command = Command::new("docker");
        command.args(["exec", "-i", &args.target, "sh", "-c", &script]);
        return Ok(command);
    }

    let control_path = control_path(&args.target)?;
    let persist = env::var("SIMPLEREMOTE_CONTROL_PERSIST").unwrap_or_else(|_| "600".to_string());
    let connect_timeout =
        env::var("SIMPLEREMOTE_CONNECT_TIMEOUT").unwrap_or_else(|_| "10".to_string());
    let mut command = Command::new("ssh");
    command
        .arg("-T")
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
        .args(["sh", "-c", &shell_quote(&script)]);
    Ok(command)
}

fn agent_script(agent: &str) -> String {
    if let Some(relative) = agent.strip_prefix("~/") {
        format!("exec \"$HOME\"/{}", shell_quote(relative))
    } else {
        format!("exec {}", shell_quote(agent))
    }
}

fn exec_script(root: &str, command: &[String]) -> String {
    let server = command
        .iter()
        .map(|value| shell_quote(value))
        .collect::<Vec<_>>()
        .join(" ");
    format!("{}; exec {server}", workspace_prelude(root))
}

fn workspace_prelude(root: &str) -> String {
    format!(
        "cd {} || exit 44; for d in \"$HOME/bin\" \"$HOME/.local/bin\" \"$PWD/env/bin\" \"$PWD/venv/bin\" \"$PWD/.conda/bin\" \"$PWD/.venv/bin\"; do [ -d \"$d\" ] && PATH=\"$d:$PATH\"; done; export PATH",
        shell_quote(root)
    )
}

fn probe_script(root: &str) -> String {
    format!(
        "{}; python=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true); lsp=$(command -v pyright-langserver 2>/dev/null || command -v basedpyright-langserver 2>/dev/null || true); node=$(command -v node 2>/dev/null || true); git=$(command -v git 2>/dev/null || true); printf 'protocol=%s\\nhost=%s\\nroot=%s\\ngit=%s\\npython=%s\\npython_version=%s\\nnode=%s\\npython_lsp=%s\\n' 'simpleremote/runtime/1' \"$(hostname 2>/dev/null || true)\" \"$PWD\" \"$git\" \"$python\" \"$([ -n \"$python\" ] && \"$python\" --version 2>&1 | head -n 1 || true)\" \"$node\" \"$lsp\"",
        workspace_prelude(root)
    )
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn control_path(target: &str) -> Result<PathBuf, String> {
    let base = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            let user = env::var("USER").unwrap_or_else(|_| "user".to_string());
            PathBuf::from(format!("/tmp/simpleremote-{user}"))
        })
        .join("simpleremote");
    ensure_private_dir(&base)?;
    Ok(base.join(format!("{:016x}.sock", fnv1a(target.as_bytes()))))
}

fn ensure_private_dir(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path).map_err(|error| {
        format!(
            "cannot create runtime directory {}: {error}",
            path.display()
        )
    })?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| {
        format!(
            "cannot secure runtime directory {}: {error}",
            path.display()
        )
    })
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn proxy(mut child: Child) -> Result<u8, String> {
    let mut child_stdin = child.stdin.take().ok_or("transport has no stdin")?;
    let mut child_stdout = child.stdout.take().ok_or("transport has no stdout")?;
    let mut child_stderr = child.stderr.take().ok_or("transport has no stderr")?;

    let _input = thread::spawn(move || {
        let _ = io::copy(&mut io::stdin().lock(), &mut child_stdin);
    });
    let output = thread::spawn(move || {
        let _ = io::copy(&mut child_stdout, &mut io::stdout().lock());
    });
    let errors = thread::spawn(move || {
        let _ = io::copy(&mut child_stderr, &mut io::stderr().lock());
    });

    let status = child
        .wait()
        .map_err(|error| format!("cannot wait for transport: {error}"))?;
    // The input thread may still be blocked on the parent pipe after a remote
    // process exits.  Dropping its handle lets the runtime return immediately;
    // process exit closes the remaining pipe descriptors.
    let _ = output.join();
    let _ = errors.join();
    Ok(status.code().unwrap_or(1).clamp(0, 255) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let valid = RuntimeArgs {
            kind: "ssh".into(),
            target: "host".into(),
            root: "/workspace".into(),
            ..RuntimeArgs::default()
        };
        assert!(validate(&valid, "probe").is_ok());
        let invalid = RuntimeArgs {
            root: "relative".into(),
            ..valid
        };
        assert!(validate(&invalid, "probe").is_err());
    }
}
