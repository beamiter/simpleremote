//! Cross-boundary transfers: `download` (remote → local) and `upload`
//! (local → remote), for single files and, with `--recursive`, whole
//! directories streamed through `tar`.
//!
//! Both directions share the same shape: bytes stream straight between the
//! transport and a temporary sibling of the destination, and the destination
//! is only ever activated by a rename.  A crashed transfer therefore leaves at
//! most a dot-prefixed `.part` entry beside the target and never a truncated
//! file where a complete one used to be.

use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::{RuntimeArgs, shell_quote, transport_command, workspace_prelude};

/// Exit statuses of the remote half; kept distinct so a failure message can
/// say which check refused the transfer.
const STATUS_WORKSPACE: i32 = 44;
const STATUS_PATH: i32 = 45;
const STATUS_BOUNDARY: i32 = 46;
const STATUS_EXISTS: i32 = 47;
const STATUS_TRUNCATED: i32 = 48;

// ---------------------------------------------------------------------------
// Remote scripts
// ---------------------------------------------------------------------------

/// Guard that keeps `$file` inside the workspace unless the caller opted out.
fn boundary_guard(allow_outside_root: bool, variable: &str) -> String {
    if allow_outside_root {
        return String::new();
    }
    format!(
        "if [ \"$base\" != / ]; then case \"${variable}\" in \"$base\"/*|\"$base\") ;; *) printf 'remote path leaves workspace: %s\\n' \"${variable}\" >&2; exit {STATUS_BOUNDARY};; esac; fi; "
    )
}

pub fn download_script(args: &RuntimeArgs) -> String {
    let remote = shell_quote(&args.remote);
    if args.recursive {
        return format!(
            "{prelude}; base=$(pwd -P) || exit {ws}; dir=$(readlink -f -- {remote} 2>/dev/null) || {{ printf 'cannot resolve remote directory: %s\\n' {remote} >&2; exit {path}; }}; {guard}[ -d \"$dir\" ] || {{ printf 'not a directory: %s\\n' \"$dir\" >&2; exit {path}; }}; exec tar -cf - -C \"$(dirname -- \"$dir\")\" -- \"$(basename -- \"$dir\")\"",
            prelude = workspace_prelude(&args.root),
            ws = STATUS_WORKSPACE,
            path = STATUS_PATH,
            guard = boundary_guard(args.allow_outside_root, "dir"),
        );
    }
    format!(
        "{prelude}; base=$(pwd -P) || exit {ws}; file=$(readlink -f -- {remote} 2>/dev/null) || {{ printf 'cannot resolve remote file: %s\\n' {remote} >&2; exit {path}; }}; {guard}[ -f \"$file\" ] || {{ printf 'not a regular file: %s\\n' \"$file\" >&2; exit {path}; }}; exec cat -- \"$file\"",
        prelude = workspace_prelude(&args.root),
        ws = STATUS_WORKSPACE,
        path = STATUS_PATH,
        guard = boundary_guard(args.allow_outside_root, "file"),
    )
}

/// The remote receiver.  It resolves the destination's parent (which must
/// exist), applies the workspace boundary to that resolved parent, refuses
/// an existing destination unless `--force`, and activates the received
/// bytes with a rename.  Files keep the mode of the file they replace, the
/// same way the agent's `write` operation does.
pub fn upload_script(args: &RuntimeArgs) -> String {
    let dest = shell_quote(&args.remote);
    let name = shell_quote(local_name(&args.local));
    let force = if args.force { "1" } else { "0" };
    let size = args.size;
    let prelude = workspace_prelude(&args.root);
    let guard = boundary_guard(args.allow_outside_root, "rdir");
    let common = format!(
        "{prelude}; base=$(pwd -P) || exit {ws}; dest={dest}; force={force}; rdir=$(cd -- \"$(dirname -- \"$dest\")\" 2>/dev/null && pwd -P) || {{ printf 'destination directory does not exist: %s\\n' \"$dest\" >&2; exit {path}; }}; {guard}dest=\"$rdir/$(basename -- \"$dest\")\"; if [ -e \"$dest\" ] || [ -L \"$dest\" ]; then [ \"$force\" = 1 ] || {{ printf 'remote destination already exists: %s\\n' \"$dest\" >&2; exit {exists}; }}; fi; ",
        ws = STATUS_WORKSPACE,
        path = STATUS_PATH,
        exists = STATUS_EXISTS,
    );
    if args.recursive {
        return format!(
            "{common}tmp=$(mktemp -d \"$rdir/.simpleremote-upload.XXXXXX\") || exit {path}; trap 'rm -rf -- \"$tmp\"' EXIT HUP INT TERM; tar -xf - -C \"$tmp\" || {{ printf 'cannot unpack upload into %s\\n' \"$rdir\" >&2; exit {path}; }}; [ -e \"$tmp/\"{name} ] || {{ printf 'upload did not contain %s\\n' {name} >&2; exit {path}; }}; if [ -e \"$dest\" ] || [ -L \"$dest\" ]; then rm -rf -- \"$dest\"; fi; mv -- \"$tmp/\"{name} \"$dest\" || exit {path}; rmdir -- \"$tmp\"; trap - EXIT; printf 'remote=%s\\n' \"$dest\"",
            path = STATUS_PATH,
        );
    }
    // `cat` reports success on any EOF, so a stream cut short by a killed
    // runtime or a dropped connection would otherwise be renamed over the
    // destination as if it were complete.  The expected length travels with
    // the script and is checked before the rename; `wc -c` and the arithmetic
    // test are POSIX, so this works on dash, busybox and BSD sh alike.
    format!(
        "{common}size={size}; if [ -d \"$dest\" ]; then printf 'remote destination is a directory: %s\\n' \"$dest\" >&2; exit {path}; fi; tmp=$(mktemp \"$rdir/.simpleremote-upload.XXXXXX\") || exit {path}; trap 'rm -f -- \"$tmp\"' EXIT HUP INT TERM; if [ -f \"$dest\" ]; then cp -p -- \"$dest\" \"$tmp\" || exit {path}; fi; cat >\"$tmp\" || exit {path}; got=$(wc -c <\"$tmp\") || exit {path}; [ \"$got\" -eq \"$size\" ] || {{ printf 'upload truncated: %s bytes of %s\\n' \"$got\" \"$size\" >&2; exit {truncated}; }}; mv -f -- \"$tmp\" \"$dest\" || exit {path}; trap - EXIT; printf 'remote=%s\\n' \"$dest\"",
        path = STATUS_PATH,
        truncated = STATUS_TRUNCATED,
    )
}

fn local_name(local: &str) -> &str {
    Path::new(local.trim_end_matches('/'))
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("upload")
}

// ---------------------------------------------------------------------------
// Local halves
// ---------------------------------------------------------------------------

fn stamp() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn part_path(destination: &Path, parent: &Path) -> PathBuf {
    let name = destination
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("transfer");
    parent.join(format!(
        ".{name}.simpleremote-{}-{}.part",
        std::process::id(),
        stamp()
    ))
}

fn destination_parent(destination: &Path) -> Result<PathBuf, String> {
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or("--local must have a parent directory")?;
    if !parent.is_dir() {
        return Err(format!(
            "local destination directory does not exist: {}",
            parent.display()
        ));
    }
    Ok(parent.to_path_buf())
}

/// Collect a child's stderr on a thread so a chatty transport can never
/// deadlock against the data pipe.
fn drain_stderr(child: &mut Child) -> Result<thread::JoinHandle<Vec<u8>>, String> {
    let mut stderr = child.stderr.take().ok_or("transport has no stderr")?;
    Ok(thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stderr.read_to_end(&mut bytes);
        bytes
    }))
}

fn describe_failure(prefix: &str, code: Option<i32>, stderr: &[u8]) -> String {
    let detail = String::from_utf8_lossy(stderr);
    let detail = detail.trim();
    let reason = match code {
        Some(STATUS_WORKSPACE) => "workspace root is unavailable",
        Some(STATUS_PATH) => "remote path check failed",
        Some(STATUS_BOUNDARY) => "remote path leaves the workspace",
        Some(STATUS_EXISTS) => "remote destination already exists",
        Some(STATUS_TRUNCATED) => "the upload was cut short and was not activated",
        _ => "transport failed",
    };
    if detail.is_empty() {
        format!("{prefix} ({}): {reason}", code.unwrap_or(1))
    } else {
        format!("{prefix} ({}): {detail}", code.unwrap_or(1))
    }
}

pub fn download(args: &RuntimeArgs) -> Result<u8, String> {
    let destination = PathBuf::from(&args.local);
    let parent = destination_parent(&destination)?;
    let existing = destination.symlink_metadata().ok();
    if existing.is_some() && !args.force {
        return Err(format!(
            "local destination already exists: {} (pass --force to replace it)",
            destination.display()
        ));
    }
    // A single file must never replace a directory, with or without --force:
    // the remote half refuses the mirror case, and sweeping away a local tree
    // is not something a file transfer may do.
    if !args.recursive && existing.as_ref().is_some_and(|metadata| metadata.is_dir()) {
        return Err(format!(
            "local destination is a directory: {}",
            destination.display()
        ));
    }
    let temporary = part_path(&destination, &parent);

    let mut command = transport_command(args, "download")?;
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("cannot start {} download: {error}", args.kind))?;
    let stdout = child.stdout.take().ok_or("download has no stdout")?;
    let errors = drain_stderr(&mut child)?;

    let result = if args.recursive {
        receive_directory(stdout, &temporary)
    } else {
        receive_file(stdout, &temporary)
    };
    let status = child
        .wait()
        .map_err(|error| format!("cannot wait for download: {error}"))?;
    let stderr = errors.join().unwrap_or_default();
    if let Err(message) = result {
        remove_any(&temporary);
        return Err(message);
    }
    if !status.success() {
        remove_any(&temporary);
        return Err(describe_failure(
            "remote download failed",
            status.code(),
            &stderr,
        ));
    }
    let copied = result.unwrap_or_default();

    let staged = if args.recursive {
        // The archive unpacked to <temporary>/<basename of the remote dir>.
        let entries: Vec<_> = fs::read_dir(&temporary)
            .map_err(|error| format!("cannot inspect {}: {error}", temporary.display()))?
            .filter_map(Result::ok)
            .collect();
        if entries.len() != 1 {
            remove_any(&temporary);
            return Err(format!(
                "download unpacked {} entries instead of one directory",
                entries.len()
            ));
        }
        entries[0].path()
    } else {
        temporary.clone()
    };
    if args.force && destination.symlink_metadata().is_ok() {
        if args.recursive {
            remove_any(&destination);
        } else {
            // Guarded above: this can only be a file or a symlink.
            let _ = fs::remove_file(&destination);
        }
    }
    if let Err(error) = fs::rename(&staged, &destination) {
        remove_any(&temporary);
        return Err(format!(
            "cannot activate download {}: {error}",
            destination.display()
        ));
    }
    if args.recursive {
        let _ = fs::remove_dir(&temporary);
        println!("downloaded_entries={copied}");
    } else {
        println!("downloaded_bytes={copied}");
    }
    println!("local={}", destination.display());
    Ok(0)
}

fn receive_file(mut stdout: impl Read, temporary: &Path) -> Result<u64, String> {
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(temporary)
        .map_err(|error| format!("cannot create {}: {error}", temporary.display()))?;
    let copied = io::copy(&mut stdout, &mut file)
        .map_err(|error| format!("download write failed: {error}"))?;
    file.sync_all()
        .map_err(|error| format!("cannot sync {}: {error}", temporary.display()))?;
    Ok(copied)
}

fn receive_directory(stdout: std::process::ChildStdout, temporary: &Path) -> Result<u64, String> {
    fs::create_dir(temporary)
        .map_err(|error| format!("cannot create {}: {error}", temporary.display()))?;
    let status = Command::new("tar")
        .arg("-xf")
        .arg("-")
        .arg("-C")
        .arg(temporary)
        .stdin(Stdio::from(stdout))
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|error| format!("cannot start local tar: {error}"))?;
    if !status.success() {
        return Err(format!("local tar failed ({})", status.code().unwrap_or(1)));
    }
    Ok(count_entries(temporary))
}

fn count_entries(path: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(path) else {
        return 0;
    };
    let mut total = 0;
    for entry in entries.flatten() {
        total += 1;
        if entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false) {
            total += count_entries(&entry.path());
        }
    }
    total
}

fn remove_any(path: &Path) {
    match path.symlink_metadata() {
        Ok(metadata) if metadata.is_dir() => {
            let _ = fs::remove_dir_all(path);
        }
        Ok(_) => {
            let _ = fs::remove_file(path);
        }
        Err(_) => {}
    }
}

pub fn upload(args: &RuntimeArgs) -> Result<u8, String> {
    // Resolve the source before anything else: `tar` archives a symlink as a
    // symlink, so a link to a directory would arrive as a dangling link
    // instead of the tree the caller meant to send.
    let source = fs::canonicalize(&args.local)
        .map_err(|error| format!("cannot resolve local source {}: {error}", args.local))?;
    let metadata = fs::metadata(&source)
        .map_err(|error| format!("cannot read local source {}: {error}", source.display()))?;
    if args.recursive && !metadata.is_dir() {
        return Err(format!(
            "--recursive needs a local directory: {}",
            source.display()
        ));
    }
    if !args.recursive && !metadata.is_file() {
        return Err(format!(
            "local source is not a regular file (pass --recursive for a directory): {}",
            source.display()
        ));
    }
    // The remote half checks the byte count before it activates the upload,
    // and the archive name must match the resolved source, not the link.
    let args = &RuntimeArgs {
        local: source.to_string_lossy().into_owned(),
        size: if args.recursive { 0 } else { metadata.len() },
        ..args.clone()
    };

    let mut command = transport_command(args, "upload")?;
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("cannot start {} upload: {error}", args.kind))?;
    let mut stdin = child.stdin.take().ok_or("upload has no stdin")?;
    let mut stdout = child.stdout.take().ok_or("upload has no stdout")?;
    let errors = drain_stderr(&mut child)?;
    let output = thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = stdout.read_to_end(&mut bytes);
        bytes
    });

    let sent: Result<u64, String> = if args.recursive {
        let parent = source
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        let name = local_name(&args.local).to_string();
        let mut tar = Command::new("tar")
            .arg("-cf")
            .arg("-")
            .arg("-C")
            .arg(&parent)
            // Without the terminator a directory named like an option (-x)
            // would be parsed as one.
            .arg("--")
            .arg(&name)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|error| format!("cannot start local tar: {error}"))?;
        let mut archive = tar.stdout.take().ok_or("local tar has no stdout")?;
        let copied = io::copy(&mut archive, &mut stdin);
        drop(stdin);
        // A remote refusal closes the pipe early.  Release tar's stdout and
        // kill it before waiting: still holding the read end would leave tar
        // blocked in write() forever, and this process blocked on it.
        drop(archive);
        if copied.is_err() {
            let _ = tar.kill();
        }
        let tar_status = tar
            .wait()
            .map_err(|error| format!("cannot wait for tar: {error}"))?;
        match copied {
            Err(error) => Err(format!("upload write failed: {error}")),
            Ok(_) if !tar_status.success() => Err(format!(
                "local tar failed ({})",
                tar_status.code().unwrap_or(1)
            )),
            Ok(bytes) => Ok(bytes),
        }
    } else {
        let mut file = fs::File::open(&source)
            .map_err(|error| format!("cannot open {}: {error}", source.display()))?;
        let copied = io::copy(&mut file, &mut stdin);
        drop(stdin);
        copied.map_err(|error| format!("upload write failed: {error}"))
    };

    let status = child
        .wait()
        .map_err(|error| format!("cannot wait for upload: {error}"))?;
    let stderr = errors.join().unwrap_or_default();
    let stdout = output.join().unwrap_or_default();
    // A remote refusal (exists, boundary) closes the pipe early; report that
    // reason rather than the EPIPE it caused on our side.
    if !status.success() {
        return Err(describe_failure(
            "remote upload failed",
            status.code(),
            &stderr,
        ));
    }
    let bytes = sent?;
    io::stdout()
        .write_all(&stdout)
        .map_err(|error| format!("cannot write upload result: {error}"))?;
    println!("uploaded_bytes={bytes}");
    println!("local={}", source.display());
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args() -> RuntimeArgs {
        RuntimeArgs {
            kind: "ssh".into(),
            target: "host".into(),
            root: "/srv/app".into(),
            remote: "/srv/app/data".into(),
            local: "/home/me/data".into(),
            ..RuntimeArgs::default()
        }
    }

    #[test]
    fn download_script_streams_a_file_or_a_tar() {
        let file = download_script(&args());
        assert!(file.contains("cd '/srv/app'"));
        assert!(file.contains("readlink -f -- '/srv/app/data'"));
        assert!(file.contains("case \"$file\" in \"$base\"/*|\"$base\")"));
        assert!(file.ends_with("exec cat -- \"$file\""));

        let tree = download_script(&RuntimeArgs {
            recursive: true,
            ..args()
        });
        assert!(tree.contains("[ -d \"$dir\" ]"));
        assert!(tree.ends_with(
            "exec tar -cf - -C \"$(dirname -- \"$dir\")\" -- \"$(basename -- \"$dir\")\""
        ));

        let anywhere = download_script(&RuntimeArgs {
            allow_outside_root: true,
            ..args()
        });
        assert!(!anywhere.contains("leaves workspace"));
    }

    #[test]
    fn upload_script_activates_by_rename_and_respects_force() {
        let file = upload_script(&args());
        assert!(file.contains("dest='/srv/app/data'; force=0;"));
        assert!(file.contains("case \"$rdir\" in \"$base\"/*|\"$base\")"));
        assert!(file.contains("cp -p -- \"$dest\" \"$tmp\""));
        assert!(file.contains("cat >\"$tmp\""));
        assert!(file.contains("mv -f -- \"$tmp\" \"$dest\""));
        assert!(file.contains("printf 'remote=%s\\n' \"$dest\""));

        let tree = upload_script(&RuntimeArgs {
            recursive: true,
            force: true,
            ..args()
        });
        assert!(tree.contains("force=1;"));
        assert!(tree.contains("mktemp -d"));
        assert!(tree.contains("tar -xf - -C \"$tmp\""));
        assert!(tree.contains("[ -e \"$tmp/\"'data' ]"));
        assert!(tree.contains("mv -- \"$tmp/\"'data' \"$dest\""));
    }

    #[test]
    fn local_name_ignores_trailing_slashes() {
        assert_eq!(local_name("/a/b/"), "b");
        assert_eq!(local_name("/a/b"), "b");
        assert_eq!(local_name("c"), "c");
    }

    #[test]
    fn failures_name_the_remote_check() {
        assert!(describe_failure("x", Some(STATUS_EXISTS), b"").contains("already exists"));
        assert!(describe_failure("x", Some(STATUS_BOUNDARY), b"").contains("leaves"));
        assert_eq!(
            describe_failure("x", Some(1), b"boom\n"),
            "x (1): boom".to_string()
        );
    }
}
