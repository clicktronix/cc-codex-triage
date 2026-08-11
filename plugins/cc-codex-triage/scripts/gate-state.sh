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
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK="$FILE.lock"
GATE_REGISTRY="$(bash "$SELF_DIR/gate-dir.sh" --registry-path)" || exit $?
REGISTRY_PARENT="$(dirname -- "$GATE_REGISTRY")"
GATE_REGISTRY_HELD=false
GATE_FILE_HELD=false

release_gate_state_locks() {
  $GATE_FILE_HELD && armed_unlock "$FILE"
  $GATE_REGISTRY_HELD && armed_unlock "$GATE_REGISTRY"
  GATE_FILE_HELD=false
  GATE_REGISTRY_HELD=false
}
trap release_gate_state_locks EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# stdin BEFORE the lock: waiting on a pipe while holding it would pin the mutex.
BODY=""
TARGET_THREAD=""
TARGET_ANCHOR=""
if [ "$VERB" = "write" ]; then
  BODY="$(cat)"
  TARGET_THREAD="$(printf '%s\n' "$BODY" | sed -n 's/^thread=//p' | head -1)"
  case "$TARGET_THREAD" in *[!a-zA-Z0-9_.-]*|'')
    echo "gate-state.sh: write body needs one valid thread= value" >&2
    exit 1
    ;;
  esac
  STATE_DIR="$(bash "$SELF_DIR/state-dir.sh")" || exit $?
  for extension in id log candidate review-state review-loop approved; do
    if [ -f "$STATE_DIR/$TARGET_THREAD.$extension" ]; then
      TARGET_ANCHOR="$STATE_DIR/$TARGET_THREAD.$extension"
      break
    fi
  done
fi
[ -n "${CC_GATE_STATE_TEST_AFTER_ANCHOR_HOOK:-}" ] \
  && . "$CC_GATE_STATE_TEST_AFTER_ANCHOR_HOOK"

[ ! -L "$REGISTRY_PARENT" ] || { echo "gate-state.sh: refusing symlinked gate registry parent" >&2; exit 2; }
[ ! -e "$REGISTRY_PARENT" ] || [ -d "$REGISTRY_PARENT" ] \
  || { echo "gate-state.sh: gate registry parent is not a directory" >&2; exit 2; }
mkdir -p "$REGISTRY_PARENT" 2>/dev/null \
  || { echo "gate-state.sh: cannot create gate registry parent" >&2; exit 2; }
[ ! -L "$GATE_REGISTRY.lock" ] \
  || { echo "gate-state.sh: refusing symlinked gate registry lock" >&2; exit 2; }

# The existing test seam belongs to the armed-file mutex. Do not accidentally
# consume it on the new outer registry mutex.
ORIGINAL_PRE_TOKEN_HOOK_SET=false
ORIGINAL_PRE_TOKEN_HOOK="${CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK:-}"
[ "${CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK+x}" = x ] && ORIGINAL_PRE_TOKEN_HOOK_SET=true
unset CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK
if armed_lock "$GATE_REGISTRY"; then
  GATE_REGISTRY_HELD=true
  registry_rc=0
else
  registry_rc=2
fi
if $ORIGINAL_PRE_TOKEN_HOOK_SET; then
  CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK="$ORIGINAL_PRE_TOKEN_HOOK"
  export CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK
else
  unset CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK
fi
[ "$registry_rc" -eq 0 ] \
  || { echo "gate-state.sh: gate registry is busy — nothing written." >&2; exit 2; }
armed_owned "$GATE_REGISTRY" \
  || { echo "gate-state.sh: lost gate registry ownership — nothing written." >&2; exit 2; }

armed_lock "$FILE" || { echo "gate-state.sh: could not acquire $LOCK — nothing written." >&2; exit 2; }
GATE_FILE_HELD=true

# Ownership is revalidated here, not just at acquisition: a holder evicted
# after stalling past the staleness window must not write over its replacement.
armed_owned "$GATE_REGISTRY" && armed_owned "$FILE" \
  || { echo "gate-state.sh: lost lock ownership before writing — nothing written." >&2; exit 2; }
if [ -n "$TARGET_ANCHOR" ] && [ ! -f "$TARGET_ANCHOR" ]; then
  echo "gate-state.sh: thread '$TARGET_THREAD' was archived while gate publication waited — nothing written." >&2
  exit 2
fi

rc=0
if [ "$VERB" = "write" ]; then
  # Per-writer temp + rename, as in the hook: no reader sees a half-written file.
  TMP="$(mktemp "$FILE.XXXXXX" 2>/dev/null)" || { echo "gate-state.sh: cannot create a temp file next to $FILE" >&2; exit 3; }
  if printf '%s\n' "$BODY" > "$TMP" 2>/dev/null && mv -f "$TMP" "$FILE" 2>/dev/null; then :; else
    rm -f "$TMP" 2>/dev/null; rc=3
  fi
else
  rm -f "$FILE" 2>/dev/null
  [ -e "$FILE" ] && rc=3
fi

armed_unlock "$FILE"
GATE_FILE_HELD=false
armed_unlock "$GATE_REGISTRY"
GATE_REGISTRY_HELD=false
[ "$rc" -eq 0 ] || echo "gate-state.sh: $VERB failed for $FILE (state dir not writable?)" >&2
exit "$rc"
