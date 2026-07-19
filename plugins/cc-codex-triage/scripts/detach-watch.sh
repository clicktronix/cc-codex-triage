#!/usr/bin/env bash
# detach-watch.sh — completion watcher for a --detach dispatch.
#
#   bash detach-watch.sh <thread> <pid>
#
# Companion to the driver's --detach mode: the detached worker is immune to
# harness process-reaping, but nothing notifies Claude when it finishes — and
# a post-READY failure writes NO new .log round, so "poll the log" never
# fires for it. This watcher closes both gaps: run it via a Claude-managed
# background Bash task (run_in_background) so its completion produces a task
# notification. It is DISPOSABLE by design — if the harness reaps it, the
# worker is unaffected and the fallback is manual log polling.
#
# Exit codes: 0 reply landed (prints it); 1 worker died with no new round
# (prints diagnostics); 2 usage; 3 timeout — worker still running; 7 not a
# git repo. Watch state is read-only: this script writes nothing.
#
# Portability: macOS bash 3.2 + Linux. No jq.

set -u

THREAD="${1:-}"
PID="${2:-}"
OFFSET="${3:-}"
[ -n "$THREAD" ] && [ -n "$PID" ] || { echo "usage: detach-watch.sh <thread> <pid> [log-offset]" >&2; exit 2; }
case "$PID" in ''|*[!0-9]*) echo "pid must be numeric" >&2; exit 2 ;; esac
case "$OFFSET" in *[!0-9]*) echo "log-offset must be numeric" >&2; exit 2 ;; esac

# Same resolved-root rule as the driver; hard-fail — watching the wrong dir
# would report "no log" for a thread that is running fine at the real root.
if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "detach-watch.sh must run inside a git repository" >&2
  exit 7
fi
cd "$ROOT" || exit 7
STATE_DIR=".claude/codex-threads"
LOG="$STATE_DIR/$THREAD.log"
DIAG="$STATE_DIR/$THREAD.last-error.jsonl"
SIDE="$STATE_DIR/$THREAD.detach-output"

# Baseline: everything appended to the log after this offset is the result.
# Prefer the launcher-provided log-offset (measured BEFORE the dispatch, so a
# reply landing before the watcher starts is still counted); fall back to the
# current size when invoked without it.
if [ -n "$OFFSET" ]; then
  BASE_BYTES="$OFFSET"
else
  BASE_BYTES="$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')"
  BASE_BYTES="${BASE_BYTES:-0}"
  case "$BASE_BYTES" in *[!0-9]*) BASE_BYTES=0 ;; esac
fi

# Poll the worker, not the log: pid death is the one signal that fires on
# BOTH success (reply appended, then exit) and post-READY failure (nothing
# appended). Bounded: CC_DETACH_WATCH_TIMEOUT seconds (default 2700 = 45min,
# past any realistic review/plan dispatch).
TIMEOUT="${CC_DETACH_WATCH_TIMEOUT:-2700}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=2700 ;; esac
WAITED=0
while kill -0 "$PID" 2>/dev/null; do
  if [ "$WAITED" -ge "$TIMEOUT" ]; then
    echo "TIMEOUT: detached dispatch (thread $THREAD, pid $PID) still running after ${TIMEOUT}s — it keeps running; re-watch or poll $LOG manually."
    exit 3
  fi
  sleep 2
  WAITED=$((WAITED + 2))
done

# Worker is gone. New log bytes → the reply landed; show exactly the delta.
CUR_BYTES="$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')"
CUR_BYTES="${CUR_BYTES:-0}"
case "$CUR_BYTES" in *[!0-9]*) CUR_BYTES=0 ;; esac
if [ "$CUR_BYTES" -gt "$BASE_BYTES" ]; then
  echo "DONE: detached dispatch on thread $THREAD finished — reply appended to $LOG:"
  tail -c "+$((BASE_BYTES + 1))" "$LOG" 2>/dev/null
  exit 0
fi
# Log rotation edge: a shrunken log means rotation happened mid-dispatch —
# the newest entry is still in the current .log (rotation precedes append).
if [ "$CUR_BYTES" -lt "$BASE_BYTES" ] && [ "$CUR_BYTES" -gt 0 ]; then
  echo "DONE: detached dispatch on thread $THREAD finished (log rotated mid-run) — current $LOG tail:"
  tail -c 65536 "$LOG" 2>/dev/null
  exit 0
fi

echo "FAILED: detached dispatch on thread $THREAD (pid $PID) exited without appending a reply to $LOG."
if [ -s "$DIAG" ]; then
  echo "--- last-error tail ($DIAG):"
  tail -c 4096 "$DIAG" 2>/dev/null
fi
if [ -s "$SIDE" ]; then
  echo "--- raw child output tail ($SIDE):"
  tail -c 4096 "$SIDE" 2>/dev/null
fi
exit 1
