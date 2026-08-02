#!/usr/bin/env bash
# cc-codex-triage — dispatch that survives the caller's timeout.
#
# usage: dispatch.sh <thread> [driver flags...]   (prompt on stdin)
#
# Same contract as codex-thread.sh: prompt in, reply on stdout and nothing else
# (`/review --json` pipes it into `jq`), status on stderr, driver exit codes.
# The two outcomes that are this wrapper's own take codes outside the driver's
# range — 20 handoff (worker STILL RUNNING), 21 outcome unconfirmed — since
# reusing 3 ("codex exec failed") would make a live dispatch look like a dead one.
#
# WHY: the Bash tool caps a foreground call at 600 s, its maximum. A branch
# review runs longer, and the dispatch simply died — the round vanished and the
# paid Codex run finished into nowhere.
#
# Detach is about process survival, not response delivery:
#   1. spawn the worker in its own session, out of reach of whatever kills us;
#   2. wait for it HERE, bounded below the caller's ceiling.
# So a short dispatch answers in-turn exactly as a direct call did; only one
# that would have been KILLED behaves differently, handing off instead. Re-run
# the watcher named in the message to collect it; the thread is untouched.
#
# --oneshot has no thread state to hand off, so it falls through to a direct
# call and keeps the old ceiling — a throwaway is cheap to repeat.
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$SELF_DIR/codex-thread.sh"
WATCHER="$SELF_DIR/detach-watch.sh"

# Foreground wait, inside the caller's 600 s ceiling with room for the handoff
# message. Length-bounded: a 20-digit value makes every `[` comparison error out.
WAIT="${CC_DISPATCH_WAIT:-540}"
case "$WAIT" in ''|*[!0-9]*) WAIT=540 ;; esac
[ "${#WAIT}" -le 6 ] || WAIT=540

THREAD=""; ONESHOT=false
for a in "$@"; do
  case "$a" in
    --oneshot) ONESHOT=true ;;
    --detach)  ;;                                  # we add it ourselves
    -*)        ;;
    *)         [ -n "$THREAD" ] || THREAD="$a" ;;
  esac
done
[ -n "$THREAD" ] || { echo "usage: dispatch.sh <thread> [driver flags...]" >&2; exit 1; }

PROMPT="$(cat)"

if $ONESHOT; then
  printf '%s' "$PROMPT" | bash "$DRIVER" "$@"
  exit $?
fi

# Detach. Anything other than a clean handshake (exit 8 = no isolator, and any
# other failure) falls back to a direct call rather than losing the dispatch.
LAUNCH="$(printf '%s' "$PROMPT" | bash "$DRIVER" "$@" --detach 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] || ! printf '%s' "$LAUNCH" | grep -q '^DETACHED pid='; then
  printf '%s\n' "$LAUNCH" >&2
  [ "$rc" -eq 8 ] && echo "dispatch.sh: no session isolator — running in the foreground, where a caller timeout can still kill this dispatch." >&2
  printf '%s' "$PROMPT" | bash "$DRIVER" "$@"
  exit $?
fi

PID="$(printf '%s' "$LAUNCH" | sed -n 's/^DETACHED pid=\([0-9][0-9]*\).*/\1/p' | head -1)"
OFF="$(printf '%s' "$LAUNCH" | sed -n 's/.*log-offset=\([0-9][0-9]*\).*/\1/p' | head -1)"
[ -n "$OFF" ] || OFF=0

CC_WATCH_PORCELAIN=1 CC_DETACH_WATCH_TIMEOUT="$WAIT" bash "$WATCHER" "$THREAD" "$PID" "$OFF"; wrc=$?
if [ "$wrc" -eq 20 ]; then
  echo "dispatch.sh: still running after ${WAIT}s — the worker is UNAFFECTED. Deliver it with:" >&2
  echo "  bash '$WATCHER' $THREAD $PID $OFF     (as a background task)" >&2
fi
exit "$wrc"
