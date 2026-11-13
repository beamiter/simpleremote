//! Cross-boundary transfers: `download` (remote → local) and `upload`
//! (local → remote), for single files and, with `--recursive`, whole
//! directories streamed through `tar`.
//!
//! Both directions share the same shape: bytes stream straight between the
//! transport and a temporary sibling of the destination, and the destination
//! is activated by a rename. Files replace without an unlink gap. Replacing
//! a directory uses a retained sibling backup and best-effort rollback: it
//! has a visibility gap and may require manual recovery after interruption.
//! None of these operations promises power-loss durability or synchronization
//! with another process modifying the same destination.

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
            r#"{common}tmp=$(mktemp -d "$rdir/.simpleremote-upload.XXXXXX") || exit {path}; backup='';
cleanup() {{
    if [ -n "$backup" ] && {{ [ -e "$backup/previous" ] || [ -L "$backup/previous" ]; }}; then
        if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
            mv -T -- "$backup/previous" "$dest" || printf 'rollback failed; previous destination retained at %s/previous\n' "$backup" >&2;
        fi;
        if [ -e "$backup/previous" ] || [ -L "$backup/previous" ]; then
            printf 'previous destination retained at %s/previous\n' "$backup" >&2;
            printf 'backup=%s/previous\n' "$backup";
        else rmdir -- "$backup"; fi;
    fi;
    rm -rf -- "$tmp";
}};
trap cleanup EXIT; trap 'exit 1' HUP INT TERM;
tar -xf - -C "$tmp" || exit {path};
[ -d "$tmp/"{name} ] && [ ! -L "$tmp/"{name} ] || exit {path};
if [ -e "$dest" ] || [ -L "$dest" ]; then
    [ "$force" = 1 ] || exit {exists};
    backup=$(mktemp -d "$rdir/.simpleremote-backup.XXXXXX") || exit {path};
    mv -T -- "$dest" "$backup/previous" || exit {path};
fi;
mv -T -- "$tmp/"{name} "$dest" || exit {path};
printf 'remote=%s\n' "$dest""#,
            path = STATUS_PATH,
            exists = STATUS_EXISTS,
        );
    }
    // `cat` reports success on any EOF, so a stream cut short by a killed
    // runtime or a dropped connection would otherwise be renamed over the
    // destination as if it were complete.  The expected length travels with
    // the script and is checked before the rename; `wc -c` and the arithmetic
    // test are POSIX, so this works on dash, busybox and BSD sh alike.
    format!(
        "{common}size={size}; if [ -d \"$dest\" ]; then printf 'remote destination is a directory: %s\\n' \"$dest\" >&2; exit {path}; fi; tmp=$(mktemp \"$rdir/.simpleremote-upload.XXXXXX\") || exit {path}; trap 'rm -f -- \"$tmp\"' EXIT HUP INT TERM; if [ -f \"$dest\" ]; then cp -p -- \"$dest\" \"$tmp\" || exit {path}; fi; cat >\"$tmp\" || exit {path}; got=$(wc -c <\"$tmp\") || exit {path}; [ \"$got\" -eq \"$size\" ] || {{ printf 'upload truncated: %s bytes of %s\\n' \"$got\" \"$size\" >&2; exit {truncated}; }}; if [ \"$force\" = 1 ]; then mv -fT -- \"$tmp\" \"$dest\" || exit {path}; else ln -T -- \"$tmp\" \"$dest\" || exit {exists}; rm -f -- \"$tmp\"; fi; trap - EXIT; printf 'remote=%s\\n' \"$dest\"",
        path = STATUS_PATH,
        truncated = STATUS_TRUNCATED,
        exists = STATUS_EXISTS,
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
        let staged = entries[0].path();
        if !staged
            .symlink_metadata()
            .is_ok_and(|metadata| metadata.is_dir())
        {
            remove_any(&temporary);
            return Err("download archive did not contain a directory".into());
        }
        staged
    } else {
        temporary.clone()
    };
    // Rename files directly: unlinking first destroys the old file on failure.
    // Non-empty directory replacement needs a recoverable two-rename transaction.
    if let Err(error) = activate_download(&staged, &destination, args.force, args.recursive) {
        remove_any(&temporary);
        return Err(error);
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

/// Directory replacement has a visibility gap. Keep the previous destination
/// in a reserved sibling even after success, so crashes never require deleting
/// the only old copy. This is recovery support, not a power-loss durability claim.
fn activate_download(
    staged: &Path,
    destination: &Path,
    force: bool,
    recursive: bool,
) -> Result<(), String> {
    activate_with(staged, destination, force, recursive, |from, to| {
        fs::rename(from, to)
    })
}

fn activate_with(
    staged: &Path,
    destination: &Path,
    force: bool,
    recursive: bool,
    mut rename: impl FnMut(&Path, &Path) -> io::Result<()>,
) -> Result<(), String> {
    let exists = destination.symlink_metadata().is_ok();
    if exists && !force {
        return Err(format!(
            "local destination already exists: {}",
            destination.display()
        ));
    }
    if !recursive && !force {
        // Same-filesystem hard link is an atomic no-clobber activation.
        fs::hard_link(staged, destination).map_err(|error| {
            format!(
                "cannot activate download {}: {error}",
                destination.display()
            )
        })?;
        let _ = fs::remove_file(staged);
        return Ok(());
    }
    if !recursive || !exists {
        return rename(staged, destination).map_err(|error| {
            format!(
                "cannot activate download {}: {error}",
                destination.display()
            )
        });
    }
    let parent = destination_parent(destination)?;
    let backup = part_path(destination, &parent).with_extension("backup");
    fs::create_dir(&backup)
        .map_err(|error| format!("cannot reserve backup {}: {error}", backup.display()))?;
    let previous = backup.join("previous");
    if let Err(error) = rename(destination, &previous) {
        let _ = fs::remove_dir(&backup);
        return Err(format!(
            "cannot preserve destination {}: {error}",
            destination.display()
        ));
    }
    if let Err(error) = rename(staged, destination) {
        // Avoid an already-observable collision; callers must exclude concurrent
        // writers because the check and rollback are not atomic.
        if destination.symlink_metadata().is_err() {
            if let Err(rollback) = rename(&previous, destination) {
                return Err(format!(
                    "activation failed: {error}; rollback failed: {rollback}; previous destination retained at {}",
                    previous.display()
                ));
            }
            let _ = fs::remove_dir(&backup);
            return Err(format!(
                "activation failed: {error}; previous destination restored"
            ));
        }
        return Err(format!(
            "activation failed: {error}; destination changed; previous destination retained at {}",
            previous.display()
        ));
    }
    eprintln!("previous destination retained at {}", previous.display());
    println!("backup={}", previous.display());
    Ok(())
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
        assert!(file.contains("mv -fT -- \"$tmp\" \"$dest\""));
        assert!(file.contains("printf 'remote=%s\\n' \"$dest\""));

        let tree = upload_script(&RuntimeArgs {
            recursive: true,
            force: true,
            ..args()
        });
        assert!(tree.contains("force=1;"));
        assert!(tree.contains("mktemp -d"));
        assert!(tree.contains("tar -xf - -C \"$tmp\""));
        assert!(tree.contains("[ -d \"$tmp/\"'data' ]"));
        assert!(tree.contains("mv -T -- \"$tmp/\"'data' \"$dest\""));
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
    struct Sandbox(PathBuf);
    impl Sandbox {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "simpleremote-replace-{}-{}",
                std::process::id(),
                stamp()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn tree(path: &Path, text: &str) {
        fs::create_dir(path).unwrap();
        fs::write(path.join("value"), text).unwrap();
    }

    #[test]
    fn file_activation_failure_preserves_original() {
        let t = Sandbox::new();
        let dst = t.0.join("dst");
        fs::write(&dst, "old").unwrap();
        assert!(activate_download(&t.0.join("absent"), &dst, true, false).is_err());
        assert_eq!(fs::read_to_string(dst).unwrap(), "old");
    }

    #[test]
    fn file_replaces_symlink_not_its_target() {
        let t = Sandbox::new();
        let dst = t.0.join("dst");
        let stage = t.0.join("stage");
        fs::write(t.0.join("original"), "old").unwrap();
        fs::write(&stage, "new").unwrap();
        std::os::unix::fs::symlink(t.0.join("original"), &dst).unwrap();
        activate_download(&stage, &dst, true, false).unwrap();
        assert_eq!(fs::read_to_string(dst).unwrap(), "new");
        assert_eq!(fs::read_to_string(t.0.join("original")).unwrap(), "old");
    }

    #[test]
    fn directory_success_retains_previous_copy() {
        let t = Sandbox::new();
        let dst = t.0.join("dst");
        let stage = t.0.join("stage");
        tree(&dst, "old");
        tree(&stage, "new");
        activate_download(&stage, &dst, true, true).unwrap();
        assert_eq!(fs::read_to_string(dst.join("value")).unwrap(), "new");
        let backup = fs::read_dir(&t.0)
            .unwrap()
            .flatten()
            .find(|e| e.path().extension().is_some_and(|v| v == "backup"))
            .unwrap();
        assert_eq!(
            fs::read_to_string(backup.path().join("previous/value")).unwrap(),
            "old"
        );
    }

    #[test]
    fn directory_failure_rolls_back_or_preserves_recovery_copy() {
        for fail_rollback in [false, true] {
            let t = Sandbox::new();
            let dst = t.0.join("dst");
            let stage = t.0.join("stage");
            tree(&dst, "old");
            tree(&stage, "new");
            let mut call = 0;
            let result = activate_with(&stage, &dst, true, true, |a, b| {
                call += 1;
                if call == 2 || (fail_rollback && call == 3) {
                    return Err(io::Error::other("injected rename failure"));
                }
                fs::rename(a, b)
            });
            let error = result.unwrap_err();
            if fail_rollback {
                assert!(error.contains("rollback failed"));
                let backup = fs::read_dir(&t.0)
                    .unwrap()
                    .flatten()
                    .find(|e| e.path().extension().is_some_and(|v| v == "backup"))
                    .unwrap();
                assert_eq!(
                    fs::read_to_string(backup.path().join("previous/value")).unwrap(),
                    "old"
                );
            } else {
                assert_eq!(fs::read_to_string(dst.join("value")).unwrap(), "old");
            }
            assert_eq!(fs::read_to_string(stage.join("value")).unwrap(), "new");
        }
    }

    #[test]
    fn force_false_rechecks_destination_before_activation() {
        let t = Sandbox::new();
        let dst = t.0.join("dst");
        let stage = t.0.join("stage");
        tree(&dst, "old");
        tree(&stage, "new");
        assert!(activate_download(&stage, &dst, false, true).is_err());
        assert_eq!(fs::read_to_string(dst.join("value")).unwrap(), "old");
    }

    #[test]
    fn remote_directory_failure_and_success_keep_old_data() {
        use std::os::unix::fs::PermissionsExt;
        for failure in ["none", "activate", "rollback"] {
            let t = Sandbox::new();
            let dst = t.0.join("dst");
            tree(&dst, "old");
            tree(&t.0.join("source"), "new");
            let archive = Command::new("tar")
                .args(["-cf", "-", "-C"])
                .arg(&t.0)
                .arg("source")
                .output()
                .unwrap();
            assert!(archive.status.success());
            let bin = t.0.join("bin");
            fs::create_dir(&bin).unwrap();
            // Fail activation and optionally rollback. Real /bin/mv handles all other calls.
            fs::write(bin.join("mv"), format!("#!/bin/sh\ncase \"$3\" in *simpleremote-upload*/source*) [ '{failure}' = none ] || exit 71;; *simpleremote-backup*/previous*) [ '{failure}' != rollback ] || exit 72;; esac\nexec /bin/mv \"$@\"\n")).unwrap();
            fs::set_permissions(bin.join("mv"), fs::Permissions::from_mode(0o755)).unwrap();
            let script = upload_script(&RuntimeArgs {
                root: t.0.to_string_lossy().into(),
                remote: dst.to_string_lossy().into(),
                local: "/unused/source".into(),
                recursive: true,
                force: true,
                ..args()
            });
            let mut child = Command::new("sh")
                .arg("-c")
                .arg(script)
                .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            child
                .stdin
                .take()
                .unwrap()
                .write_all(&archive.stdout)
                .unwrap();
            let out = child.wait_with_output().unwrap();
            assert_eq!(
                out.status.success(),
                failure == "none",
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
            if failure == "activate" {
                assert_eq!(fs::read_to_string(dst.join("value")).unwrap(), "old");
            } else {
                let backup = fs::read_dir(&t.0)
                    .unwrap()
                    .flatten()
                    .find(|e| {
                        e.file_name()
                            .to_string_lossy()
                            .starts_with(".simpleremote-backup.")
                    })
                    .unwrap();
                assert_eq!(
                    fs::read_to_string(backup.path().join("previous/value")).unwrap(),
                    "old"
                );
                if failure == "none" {
                    assert_eq!(fs::read_to_string(dst.join("value")).unwrap(), "new");
                } else {
                    assert!(String::from_utf8_lossy(&out.stderr).contains("rollback failed"));
                }
            }
        }
    }
    #[test]
    fn remote_file_no_force_does_not_clobber_midstream_creation() {
        let t = Sandbox::new();
        let dst = t.0.join("dst");
        let script = upload_script(&RuntimeArgs {
            root: t.0.to_string_lossy().into(),
            remote: dst.to_string_lossy().into(),
            size: 3,
            force: false,
            ..args()
        });
        // Inject a concurrent destination after reception, before activation.
        let script = script.replace("got=$(wc -c", "printf old >\"$dest\"; got=$(wc -c");
        let mut child = Command::new("sh")
            .arg("-c")
            .arg(script)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"new").unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(!out.status.success());
        assert_eq!(fs::read_to_string(dst).unwrap(), "old");
    }

    #[test]
    fn interrupted_remote_directory_activation_restores_old_destination() {
        let t = Sandbox::new();
        let dst = t.0.join("dst");
        tree(&dst, "old");
        tree(&t.0.join("source"), "new");
        let archive = Command::new("tar")
            .args(["-cf", "-", "-C"])
            .arg(&t.0)
            .arg("source")
            .output()
            .unwrap();
        let script = upload_script(&RuntimeArgs {
            root: t.0.to_string_lossy().into(),
            remote: dst.to_string_lossy().into(),
            local: "/unused/source".into(),
            recursive: true,
            force: true,
            ..args()
        });
        // Interrupt after the backup rename, before activating received content.
        let script = script.replace(
            "mv -T -- \"$tmp/\"'source'",
            "kill -TERM $$; mv -T -- \"$tmp/\"'source'",
        );
        let mut child = Command::new("sh")
            .arg("-c")
            .arg(script)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&archive.stdout)
            .unwrap();
        assert!(!child.wait_with_output().unwrap().status.success());
        assert_eq!(fs::read_to_string(dst.join("value")).unwrap(), "old");
    }
}
