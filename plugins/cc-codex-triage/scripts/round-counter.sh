#!/usr/bin/env bash
# Read a persisted dispatch counter with one grammar for the driver and review gate.
# Missing or malformed content normalizes to zero; unsafe filesystem objects fail closed.
set -u

FILE="${1:-}"
[ -n "$FILE" ] || { echo "usage: round-counter.sh <rounds-file>" >&2; exit 1; }
[ ! -L "$FILE" ] || { echo "refusing symlinked round counter: $FILE" >&2; exit 7; }
[ ! -e "$FILE" ] || [ -f "$FILE" ] \
  || { echo "round counter is not a regular file: $FILE" >&2; exit 7; }

VALUE="$(cat "$FILE" 2>/dev/null)" || VALUE=""
case "$VALUE" in *$'\n'*) VALUE="" ;; esac
if [ "${#VALUE}" -le 7 ] && printf '%s\n' "$VALUE" | LC_ALL=C grep -Eq '^(0|[1-9][0-9]*)$'; then
  printf '%s\n' "$VALUE"
else
  printf '0\n'
fi
