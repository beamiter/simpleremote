#!/bin/sh
# Builds the SimpleRemote runtime and installs it into lib/.
#
# STAND-IN.  Every other Rust plugin in the suite sources the shared
# install-common.sh vendored from simplecore, which is where these checks are
# maintained and where a change to them belongs.  SimpleRemote is not onboarded
# to that bundle yet, so the guarantees it provides are spelled out here rather
# than dropped: refuse a toolchain that cannot build this crate, build for the
# host triple, prove the freshly built binary works before it replaces a daemon
# Vim is using, and swap it in atomically.  Onboarding this plugin means
# deleting this body in favour of `. install-common.sh`, not maintaining a
# second copy of it.
#
# Deliberately POSIX sh, as this file has always been; install-common.sh is
# bash, so the two spellings differ even where the behaviour does not.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"

binary=simpleremote-daemon
display=SimpleRemote

# ── preconditions ────────────────────────────────────────────────────────────

# The minimum is read from Cargo.toml rather than written out again here:
# stating it twice is how a bump leaves one copy behind, and a stale minimum
# does not fail a build — cargo refuses to compile at all, with a message about
# something else.  .github/workflows/ci.yml derives its MSRV job the same way.
min_rust=$(sed -n 's/^rust-version *= *"\([0-9.]*\)".*/\1/p' Cargo.toml)
if [ -z "$min_rust" ]; then
	echo "error: Cargo.toml declares no rust-version." >&2
	exit 1
fi

# Compare major.minor only; a patch release never moves the language level.
rust_at_least() {
	have_major=${1%%.*}
	have_rest=${1#*.}
	have_minor=${have_rest%%.*}
	want_major=${2%%.*}
	want_rest=${2#*.}
	want_minor=${want_rest%%.*}
	if [ "$have_major" -ne "$want_major" ]; then
		[ "$have_major" -gt "$want_major" ]
		return
	fi
	[ "$have_minor" -ge "$want_minor" ]
}

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
	echo "error: $display needs Rust $min_rust or newer and Cargo." >&2
	echo "       Install them from https://rustup.rs and run this script again." >&2
	exit 1
fi

# Refuse early rather than let the user read a page of trait-resolution errors
# and conclude the plugin is broken.
rustc_version=$(rustc --version)
found_rust=$(printf '%s\n' "$rustc_version" |
	sed -n 's/^rustc \([0-9][0-9]*\.[0-9][0-9]*\)[.-].*/\1/p')
if [ -z "$found_rust" ]; then
	echo "error: could not read a version out of: $rustc_version" >&2
	exit 1
fi
if ! rust_at_least "$found_rust" "$min_rust"; then
	echo "error: $display needs Rust $min_rust or newer; found $rustc_version." >&2
	exit 1
fi

# ── build ────────────────────────────────────────────────────────────────────

# An installer must produce a binary runnable on this machine.  Naming the
# target and the target directory explicitly overrides a build.target in the
# user's cargo config — which would otherwise move the artifact out from under
# `target/release` — and gives one fresh path instead of a stale one.
host=$(rustc -vV | sed -n 's/^host: //p')
if [ -z "$host" ]; then
	echo "error: rustc did not report its host target." >&2
	exit 1
fi
suffix=""
case "$host" in
*windows*) suffix=".exe" ;;
esac

cargo build \
	--manifest-path Cargo.toml \
	--release \
	--locked \
	--bin "$binary" \
	--target "$host" \
	--target-dir "$root/target"

source_binary="target/$host/release/$binary$suffix"
if [ ! -f "$source_binary" ] || [ ! -x "$source_binary" ]; then
	echo "error: the build succeeded but $binary$suffix was not where it was expected." >&2
	echo "       Expected: $root/$source_binary" >&2
	exit 1
fi

# ── verify ───────────────────────────────────────────────────────────────────

# Check the daemon before replacing a working one with it.  A build that
# succeeds but produces a broken binary — a half-applied dependency bump, a
# corrupt link — fails here instead of at the user's next connection.
if ! "$source_binary" --self-test >/dev/null; then
	echo "error: the freshly built $binary failed its self-test; nothing was installed." >&2
	exit 1
fi
if ! reported_version=$("$source_binary" --version); then
	echo "error: the freshly built $binary could not report its version; nothing was installed." >&2
	exit 1
fi

# ── install ──────────────────────────────────────────────────────────────────

# Replace atomically.  Writing over the destination in place fails with ETXTBSY
# while Vim still has the old daemon running, and a partial copy would leave a
# corrupt binary behind — mv over the same filesystem cannot.
if [ -L lib ]; then
	echo "error: $root/lib must not be a symbolic link." >&2
	exit 1
fi
mkdir -p lib
destination="lib/$binary$suffix"
if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
	echo "error: $root/$destination must be a regular file or absent." >&2
	exit 1
fi
if ! (
	temporary=$(mktemp "lib/.$binary.XXXXXX")
	trap 'rm -f -- "$temporary"' EXIT
	cp -- "$source_binary" "$temporary"
	# No `--` for chmod: BSD chmod (which is what macOS ships) takes it as a
	# file name and fails.  Every path here begins with `lib/`, so there is
	# nothing for the terminator to protect against.
	chmod 0755 "$temporary"
	mv -f -- "$temporary" "$destination"
	trap - EXIT
); then
	echo "error: could not atomically install $binary; the old binary is unchanged." >&2
	exit 1
fi

# ── help tags ────────────────────────────────────────────────────────────────

if [ -d doc ]; then
	if command -v vim >/dev/null 2>&1; then
		vim -Nu NONE -n -i NONE -es -c 'helptags doc' -c 'qa!'
	else
		echo "note: Vim is not on PATH; run :helptags $root/doc yourself." >&2
	fi
fi

echo "Installed ${reported_version:-$binary} to $root/$destination"
echo "Ensure $root is on Vim's 'runtimepath'."
