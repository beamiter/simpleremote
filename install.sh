#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"

cargo build --release --locked
mkdir -p lib
tmp="lib/.simpleremote-daemon.$$"
cp target/release/simpleremote-daemon "$tmp"
chmod 755 "$tmp"
mv "$tmp" lib/simpleremote-daemon
printf 'SimpleRemote Rust runtime installed: %s\n' "$root/lib/simpleremote-daemon"
