#!/bin/sh
set -eu

# A pre-list-encoding agent used to prove the new Vim side negotiates down to
# list-meta/list without requiring a protocol-version bump.
encode() { base64 | tr -d '\n'; }
reply() {
  printf '%s\t%s\t' "$1" "$2"
  printf '%s' "$3" | encode
  printf '\n'
}
reply_stream() {
  printf '%s\t%s\t' "$1" "$2"
  encode
  printf '\n'
}

tab=$(printf '\t')
while IFS="$tab" read -r id op payload; do
  [ -n "${id:-}" ] || continue
  if [ -n "${SIMPLEREMOTE_TEST_LEGACY_OP_LOG:-}" ]; then
    printf '%s\n' "$op" >>"$SIMPLEREMOTE_TEST_LEGACY_OP_LOG"
  fi
  case "$op" in
    ping)
      reply "$id" ok 'simpleremote/2'
      ;;
    read-config)
      reply "$id" error 'config not found: legacy fixture'
      ;;
    list-meta)
      printf 'legacy.txt\tf\t6\t123\n' | reply_stream "$id" ok
      ;;
    list)
      printf 'legacy.txt\tf\n' | reply_stream "$id" ok
      ;;
    *)
      reply "$id" error "unknown operation: $op"
      ;;
  esac
done
