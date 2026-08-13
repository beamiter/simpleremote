use std::env;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::thread;

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
    if action != "agent" && action != "exec" {
        return Err("usage: simpleremote-daemon {agent|exec} [options]".to_string());
    }

    let parsed = parse_args(args.collect())?;
    validate(&parsed, &action)?;
    let mut command = transport_command(&parsed, &action)?;
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
    if action == "exec" {
        if !args.root.starts_with('/') {
            return Err("--root must be absolute".to_string());
        }
        if args.command.is_empty() {
            return Err("a command is required after --".to_string());
        }
    }
    Ok(())
}

fn transport_command(args: &RuntimeArgs, action: &str) -> Result<Command, String> {
    let script = if action == "agent" {
        agent_script(&args.agent)
    } else {
        exec_script(&args.root, &args.command)
    };
    if args.kind == "docker" {
        let mut command = Command::new("docker");
        command.args(["exec", "-i", &args.target, "sh", "-c", &script]);
        return Ok(command);
    }

    let control_path = control_path(&args.target)?;
    let persist = env::var("SIMPLEREMOTE_CONTROL_PERSIST").unwrap_or_else(|_| "600".to_string());
    let mut command = Command::new("ssh");
    command
        .arg("-T")
        .arg("-o")
        .arg("ControlMaster=auto")
        .arg("-o")
        .arg(format!("ControlPersist={persist}"))
        .arg("-o")
        .arg(format!("ControlPath={}", control_path.display()))
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
    format!(
        "cd {} && if [ -d .venv/bin ]; then PATH=\"$PWD/.venv/bin:$PATH\"; export PATH; fi; exec {server}",
        shell_quote(root)
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
