#!/usr/bin/env bash
# cc-codex-triage — the only writer of gate armed-state outside the Stop hook.
#
#   gate-state.sh write  <armed-file>    # body on stdin, replaces the file
#   gate-state.sh remove <armed-file>    # disarm
#
# The Stop hook serializes its three armed-file writers under a per-file mkdir
# mutex, because all of them rewrite the WHOLE file. Arming and disarming did it
# straight from a command snippet, outside that mutex — so a turn-end hook could
# overwrite a fresh arming, or resurrect a gate just switched off.
#
# The mutex itself lives in lib.sh, which this sources; the hook keeps its own
# copy because it must stay sourceless.
#
# Exit: 0 done, 1 usage, 2 could not acquire the lock (nothing written), 3 the
# write/remove itself failed. Callers must not treat 2 as success: the point of
# refusing is that a half-applied arming is worse than none.
set -u

VERB="${1:-}"
FILE="${2:-}"
case "$VERB" in write|remove) ;; *) echo "usage: gate-state.sh {write|remove} <armed-file>" >&2; exit 1 ;; esac
[ -n "$FILE" ] || { echo "usage: gate-state.sh {write|remove} <armed-file>" >&2; exit 1; }

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
LOCK="$FILE.lock"

# stdin BEFORE the lock: waiting on a pipe while holding it would pin the mutex.
BODY=""
if [ "$VERB" = "write" ]; then BODY="$(cat)"; fi

armed_lock "$FILE" || { echo "gate-state.sh: could not acquire $LOCK — nothing written." >&2; exit 2; }

rc=0
if [ "$VERB" = "write" ]; then
  # Per-writer temp + rename, as in the hook: no reader sees a half-written file.
  TMP="$(mktemp "$FILE.XXXXXX" 2>/dev/null)" || { armed_unlock "$FILE"; echo "gate-state.sh: cannot create a temp file next to $FILE" >&2; exit 3; }
  if printf '%s\n' "$BODY" > "$TMP" 2>/dev/null && mv -f "$TMP" "$FILE" 2>/dev/null; then :; else
    rm -f "$TMP" 2>/dev/null; rc=3
  fi
else
  rm -f "$FILE" 2>/dev/null
  [ -e "$FILE" ] && rc=3
fi

armed_unlock "$FILE"
[ "$rc" -eq 0 ] || echo "gate-state.sh: $VERB failed for $FILE (state dir not writable?)" >&2
exit "$rc"
