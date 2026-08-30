#!/bin/sh
# What install.sh must refuse before it overwrites a daemon Vim is using.
#
# The nine bundle plugins get these checks from the shared install-common.sh;
# SimpleRemote is not onboarded yet and spells them out itself, so they need a
# gate of their own or they rot.  Every toolchain here is a stub, so nothing is
# compiled and the real lib/simpleremote-daemon is never touched: each case
# runs install.sh inside a throwaway plugin root of its own.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/simpleremote-install-guard.XXXXXX")
trap 'rm -rf -- "$work"' EXIT INT TERM

failures=0
fail() {
	printf 'install_guard: FAIL %s\n' "$1" >&2
	failures=$((failures + 1))
}

# A triple no machine has, so a pass proves install.sh built for the host rustc
# reported instead of assuming target/release.
host=x99-unknown-linux-gnu

min_rust=$(sed -n 's/^rust-version *= *"\([0-9.]*\)".*/\1/p' "$root/Cargo.toml")
if [ -z "$min_rust" ]; then
	echo "install_guard: Cargo.toml declares no rust-version" >&2
	exit 1
fi
min_major=${min_rust%%.*}
min_rest=${min_rust#*.}
min_minor=${min_rest%%.*}
too_old="$min_major.$((min_minor - 1)).0"
new_enough="$min_major.$((min_minor + 1)).0"

# ── stub toolchain ───────────────────────────────────────────────────────────

stub_bin="$work/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/rustc" <<'STUB'
#!/bin/sh
case "${1:-}" in
--version) printf 'rustc %s (0000000 2020-01-01)\n' "$STUB_RUST_VERSION" ;;
-vV) printf 'rustc %s (0000000 2020-01-01)\nhost: %s\n' "$STUB_RUST_VERSION" "$STUB_HOST" ;;
*) exit 64 ;;
esac
STUB

# Writes the daemon only under target/<triple>/release, never target/release,
# so an installer that looks in the wrong place finds nothing.
cat >"$stub_bin/cargo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_CARGO_LOG"
target=""
target_dir=""
previous=""
for argument in "$@"; do
	case "$previous" in
	--target) target=$argument ;;
	--target-dir) target_dir=$argument ;;
	esac
	previous=$argument
done
[ -n "$target" ] || { echo "stub cargo: no --target was passed" >&2; exit 1; }
[ -n "$target_dir" ] || { echo "stub cargo: no --target-dir was passed" >&2; exit 1; }
mkdir -p "$target_dir/$target/release"
cp "$STUB_DAEMON" "$target_dir/$target/release/simpleremote-daemon"
chmod 755 "$target_dir/$target/release/simpleremote-daemon"
STUB

# A working daemon.
cat >"$work/daemon-good" <<'STUB'
#!/bin/sh
case "${1:-}" in
--self-test) echo ok ;;
--version) echo "simpleremote-daemon 9.9.9-stub" ;;
*) exit 64 ;;
esac
STUB

# One that builds and reports its version but fails the self-test: the corrupt
# link, the half-applied dependency bump.
cat >"$work/daemon-broken" <<'STUB'
#!/bin/sh
case "${1:-}" in
--self-test) echo "self-test failed" >&2; exit 1 ;;
--version) echo "simpleremote-daemon 9.9.9-stub" ;;
*) exit 64 ;;
esac
STUB

# The daemon as it was before --self-test existed: an unknown argument is a
# usage error.  An installer that claims to self-test must refuse this one.
cat >"$work/daemon-without-self-test" <<'STUB'
#!/bin/sh
case "${1:-}" in
--version) echo "simpleremote-daemon 9.9.9-stub" ;;
*) echo "usage: simpleremote-daemon {agent|exec|probe}" >&2; exit 2 ;;
esac
STUB

chmod 755 "$stub_bin/rustc" "$stub_bin/cargo" \
	"$work/daemon-good" "$work/daemon-broken" "$work/daemon-without-self-test"

# ── harness ──────────────────────────────────────────────────────────────────

sandbox=""
status=0

new_sandbox() {
	sandbox=$(mktemp -d "$work/sandbox.XXXXXX")
	cp "$root/install.sh" "$sandbox/install.sh"
	chmod 755 "$sandbox/install.sh"
	cp "$root/Cargo.toml" "$sandbox/Cargo.toml"
	mkdir -p "$sandbox/lib" "$sandbox/doc"
	printf 'the daemon Vim is already running\n' >"$sandbox/lib/simpleremote-daemon"
	chmod 755 "$sandbox/lib/simpleremote-daemon"
	printf '*simpleremote.txt*\tstub\n' >"$sandbox/doc/simpleremote.txt"
}

run_install() {
	if PATH="$stub_bin:$PATH" \
		STUB_RUST_VERSION="$1" \
		STUB_HOST="$host" \
		STUB_DAEMON="$2" \
		STUB_CARGO_LOG="$sandbox/cargo.log" \
		"$sandbox/install.sh" >"$sandbox/out" 2>"$sandbox/err"; then
		status=0
	else
		status=$?
	fi
}

expect_failure() {
	[ "$status" -ne 0 ] || fail "$1: install.sh returned success"
}

expect_stderr() {
	grep -q -- "$1" "$sandbox/err" ||
		fail "$2: stderr was <$(tr '\n' ' ' <"$sandbox/err")>"
}

expect_installed_daemon_unchanged() {
	[ "$(cat "$sandbox/lib/simpleremote-daemon")" = "the daemon Vim is already running" ] ||
		fail "$1: the installed daemon was replaced anyway"
}

expect_no_staging_leftovers() {
	leftovers=$(find "$sandbox/lib" -name '.simpleremote-daemon.*' 2>/dev/null || true)
	[ -z "$leftovers" ] || fail "$1: staging files were left behind: $leftovers"
}

# ── a toolchain that cannot build this crate is refused ──────────────────────

new_sandbox
run_install "$too_old" "$work/daemon-good"
expect_failure "old-rust"
expect_stderr "needs Rust $min_rust or newer" "old-rust: no minimum was named"
expect_installed_daemon_unchanged "old-rust"
[ ! -f "$sandbox/cargo.log" ] || fail "old-rust: cargo ran before the version was checked"

# ── a binary that cannot pass its own self-test is not installed ─────────────

new_sandbox
run_install "$new_enough" "$work/daemon-broken"
expect_failure "broken-daemon"
expect_stderr "failed its self-test" "broken-daemon: the self-test was not what refused it"
expect_stderr "nothing was installed" "broken-daemon: the refusal did not say so"
expect_installed_daemon_unchanged "broken-daemon"
expect_no_staging_leftovers "broken-daemon"

# ── a daemon with no --self-test at all is refused, not waved through ────────

new_sandbox
run_install "$new_enough" "$work/daemon-without-self-test"
expect_failure "no-self-test"
expect_stderr "failed its self-test" "no-self-test: a daemon without --self-test was accepted"
expect_installed_daemon_unchanged "no-self-test"

# ── the good path installs atomically, from the host triple ─────────────────

new_sandbox
run_install "$new_enough" "$work/daemon-good"
[ "$status" -eq 0 ] ||
	fail "good: install.sh failed: <$(tr '\n' ' ' <"$sandbox/err")>"
grep -q -- "--target $host" "$sandbox/cargo.log" ||
	fail "good: cargo was not asked for the host triple: <$(cat "$sandbox/cargo.log")>"
grep -q -- "--target-dir" "$sandbox/cargo.log" ||
	fail "good: cargo was not given an explicit target directory"
[ ! -e "$sandbox/target/release/simpleremote-daemon" ] ||
	fail "good: the test built the wrong path, so it proves nothing"
grep -q '^--self-test) echo ok' "$sandbox/lib/simpleremote-daemon" ||
	fail "good: the freshly built daemon was not installed"
[ -x "$sandbox/lib/simpleremote-daemon" ] || fail "good: the installed daemon is not executable"
expect_no_staging_leftovers "good"
grep -q "9.9.9-stub" "$sandbox/out" ||
	fail "good: the reported version was never read: <$(cat "$sandbox/out")>"
if command -v vim >/dev/null 2>&1; then
	[ -f "$sandbox/doc/tags" ] || fail "good: help tags were not regenerated"
fi

# ── the install path is never followed out of the plugin root ────────────────

new_sandbox
outside="$work/outside-$$"
mkdir -p "$outside"
rm "$sandbox/lib/simpleremote-daemon"
ln -s "$outside/planted" "$sandbox/lib/simpleremote-daemon"
run_install "$new_enough" "$work/daemon-good"
expect_failure "symlinked-destination"
expect_stderr "regular file or absent" "symlinked-destination: the refusal did not name the cause"
[ ! -e "$outside/planted" ] || fail "symlinked-destination: the symlink was followed out of lib"
[ -L "$sandbox/lib/simpleremote-daemon" ] || fail "symlinked-destination: the symlink was replaced"

new_sandbox
rm -r "$sandbox/lib"
ln -s "$work" "$sandbox/lib"
run_install "$new_enough" "$work/daemon-good"
expect_failure "symlinked-lib"
expect_stderr "must not be a symbolic link" "symlinked-lib: the refusal did not name the cause"
[ ! -e "$work/simpleremote-daemon" ] || fail "symlinked-lib: the daemon was installed outside the plugin"

# ── a missing toolchain says how to get one ──────────────────────────────────

if PATH=/usr/bin:/bin command -v cargo >/dev/null 2>&1; then
	echo "install_guard: skipping the missing-cargo case; cargo is in /usr/bin" >&2
else
	mkdir -p "$work/rustc-only"
	cp "$stub_bin/rustc" "$work/rustc-only/rustc"
	new_sandbox
	if PATH="$work/rustc-only:/usr/bin:/bin" \
		STUB_RUST_VERSION="$new_enough" \
		STUB_HOST="$host" \
		STUB_DAEMON="$work/daemon-good" \
		STUB_CARGO_LOG="$sandbox/cargo.log" \
		"$sandbox/install.sh" >"$sandbox/out" 2>"$sandbox/err"; then
		status=0
	else
		status=$?
	fi
	expect_failure "no-cargo"
	expect_stderr "rustup.rs" "no-cargo: the refusal did not say where to get Rust"
	expect_installed_daemon_unchanged "no-cargo"
fi

if [ "$failures" -ne 0 ]; then
	echo "install_guard: $failures check(s) failed" >&2
	exit 1
fi
echo "install_guard: ok"
