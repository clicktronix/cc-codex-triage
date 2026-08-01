#!/usr/bin/env bash
# cc-codex-triage — dispatch that survives the caller's timeout.
#
# usage: dispatch.sh <thread> [driver flags...]   (prompt on stdin)
#
# Same contract as codex-thread.sh — prompt in, reply on stdout, driver exit
# codes — with one difference: the dispatch is detached first, so a caller
# timeout can no longer kill it.
#
# WHY THIS EXISTS. The Bash tool caps a foreground call at 600 s; that is its
# maximum, not a setting. A branch review routinely runs longer, and when the
# cap hit, the dispatch died: the round vanished, the paid Codex run finished
# into nowhere, and nothing was written anywhere. It happened twice in one
# session while this was being written.
#
# DETACH IS ABOUT PROCESS SURVIVAL, NOT RESPONSE DELIVERY — the two are
# separable, and separating them is the whole point:
#
#   1. spawn the worker in its own session (`--detach`), so nothing that kills
#      this process can reach it;
#   2. wait for it HERE, in the foreground, bounded below the caller's ceiling.
#
# A short dispatch therefore behaves exactly as a plain foreground call: the
# reply comes back in the same turn. Only a dispatch that would previously have
# been killed changes behaviour — it becomes a handoff instead of a loss.
#
# On handoff (exit 3) the worker is still running: re-run the watcher named in
# the message as a background task and its completion notification delivers the
# reply. The thread is untouched either way.
#
# --oneshot cannot detach (there is no thread state to hand off), so it falls
# through to a direct call and keeps the old ceiling. That is acceptable: a
# throwaway leaves nothing behind, so a lost one is cheap to repeat.
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$SELF_DIR/codex-thread.sh"
WATCHER="$SELF_DIR/detach-watch.sh"

# Seconds to wait in the foreground. Default 540 — comfortably inside a 600 s
# ceiling, leaving room for the handoff message. Override for a caller with a
# different limit.
WAIT="${CC_DISPATCH_WAIT:-540}"
case "$WAIT" in ''|*[!0-9]*) WAIT=540 ;; esac

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

CC_DETACH_WATCH_TIMEOUT="$WAIT" bash "$WATCHER" "$THREAD" "$PID" "$OFF"; wrc=$?
if [ "$wrc" -eq 3 ]; then
  echo "dispatch.sh: still running after ${WAIT}s — the worker is UNAFFECTED. Deliver it with:" >&2
  echo "  bash '$WATCHER' $THREAD $PID $OFF     (as a background task)" >&2
fi
exit "$wrc"
