#!/usr/bin/env bash
# cc-codex-triage — the only writer of gate armed-state outside the Stop hook.
#
#   gate-state.sh write  <armed-file>    # body on stdin, replaces the file
#   gate-state.sh remove <armed-file>    # disarm
#
# WHY. The Stop hook serializes its three writers (block counter, idle
# consumption, cycle rebaseline) under a per-file mkdir mutex, because all of
# them rewrite the WHOLE file and an unserialized one drops whatever a
# concurrent writer just put there. Arming and disarming rewrite the same file
# and were doing it straight from a command snippet, outside that mutex — so a
# turn-end hook could overwrite a fresh arming with the previous cycle's
# counters, or resurrect a gate the user had just switched off.
#
# The lock protocol is duplicated here rather than shared, because the hook is
# deliberately dependency-free (see lib.sh's header). It must stay identical:
#   - mkdir is the atomic primitive;
#   - the owner token distinguishes OUR lock from a replacement, so a release
#     never removes a lock somebody else now holds;
#   - a lock older than 30s is stale by construction, and the steal is gated on
#     an unchanged mtime plus an atomic rename.
# CHANGE BOTH TOGETHER.
#
# Exit: 0 done, 1 usage, 2 could not acquire the lock (nothing written), 3 the
# write/remove itself failed. Callers must not treat 2 as success: the point of
# refusing is that a half-applied arming is worse than none.
set -u

VERB="${1:-}"
FILE="${2:-}"
case "$VERB" in write|remove) ;; *) echo "usage: gate-state.sh {write|remove} <armed-file>" >&2; exit 1 ;; esac
[ -n "$FILE" ] || { echo "usage: gate-state.sh {write|remove} <armed-file>" >&2; exit 1; }

TOKEN="$$.${RANDOM:-0}${RANDOM:-0}"
LOCK="$FILE.lock"

_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null; }

acquire() {
  local i=0 now m1 m2
  while [ "$i" -lt 25 ]; do
    if mkdir "$LOCK" 2>/dev/null; then
      printf '%s' "$TOKEN" > "$LOCK/owner" 2>/dev/null || true
      return 0
    fi
    now="$(date +%s 2>/dev/null)" || return 1
    m1="$(_mtime "$LOCK")"
    case "${m1:-}" in ''|*[!0-9]*) m1="" ;; esac
    if [ -n "$m1" ] && [ "$(( now - m1 ))" -gt 30 ]; then
      m2="$(_mtime "$LOCK")"
      if [ "$m1" = "$m2" ] && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
        rm -rf "$LOCK.stale.$$" 2>/dev/null
      fi
      i=$((i+1)); continue
    fi
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i+1))
  done
  return 1
}
release() {
  [ "$(cat "$LOCK/owner" 2>/dev/null)" = "$TOKEN" ] || return 0
  rm -rf "$LOCK" 2>/dev/null
}

# stdin is read BEFORE the lock: holding it while waiting on a pipe would pin
# the mutex for as long as the caller takes to produce the body.
BODY=""
if [ "$VERB" = "write" ]; then BODY="$(cat)"; fi

acquire || { echo "gate-state.sh: could not acquire $LOCK — nothing written." >&2; exit 2; }

rc=0
if [ "$VERB" = "write" ]; then
  # Same per-writer temp + rename as the hook: a reader must never see a
  # half-written armed file, and a shared temp name would let two writers
  # truncate each other.
  TMP="$(mktemp "$FILE.XXXXXX" 2>/dev/null)" || { release; echo "gate-state.sh: cannot create a temp file next to $FILE" >&2; exit 3; }
  if printf '%s\n' "$BODY" > "$TMP" 2>/dev/null && mv -f "$TMP" "$FILE" 2>/dev/null; then :; else
    rm -f "$TMP" 2>/dev/null; rc=3
  fi
else
  rm -f "$FILE" 2>/dev/null
  [ -e "$FILE" ] && rc=3
fi

release
[ "$rc" -eq 0 ] || echo "gate-state.sh: $VERB failed for $FILE (state dir not writable?)" >&2
exit "$rc"
