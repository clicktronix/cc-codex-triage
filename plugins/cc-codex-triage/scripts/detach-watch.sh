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
# Exit codes: 0 worker succeeded (prints the reply + any warnings); 1 worker
# failed (prints its rc + diagnostics); 2 usage; 3 timeout — worker still
# running; 4 UNKNOWN — no status record matches this PID (SIGKILL, or a
# newer launch already replaced it): treat as failure until confirmed —
# log growth alone is never read as success; 7 not a git repo. Watch state
# is read-only: this script writes nothing.
#
# CC_WATCH_PORCELAIN=1 switches to the MACHINE contract, for a caller that
# forwards this output as if it were the driver's own (dispatch.sh):
#   - stdout is byte-identical to the reply, nothing else. The default mode
#     prefixes a `DONE:` line, which is right for a notification a human or an
#     agent reads but breaks `/review --json`, whose next step is `jq`.
#   - the exit status is the WORKER's, so 3/4/5 survive instead of collapsing
#     into 1 and losing the caller's ability to recover per cause. The two
#     outcomes that are the watcher's own get codes outside the driver's range:
#     20 timeout (handoff — the worker is alive), 21 unconfirmed.
#
# Portability: macOS bash 3.2 + Linux. No jq.

set -u
PORCELAIN="${CC_WATCH_PORCELAIN:-0}"
# fd 3 is the real stdout. In porcelain mode everything printed normally lands
# on stderr, so only the explicit `>&3` writes — the reply — reach stdout.
if [ "$PORCELAIN" = "1" ]; then exec 3>&1 1>&2; else exec 3>&1; fi

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
ERRS="$STATE_DIR/$THREAD.detach-stderr"

# Diagnostic baseline for failure/UNKNOWN output. Success reads the worker-owned
# detach-output sidecar directly, so a later foreground round on the same thread
# cannot be misattributed to this dispatch. Prefer the launcher-provided offset;
# fall back to the current size when invoked without it.
if [ -n "$OFFSET" ]; then
  BASE_BYTES="$OFFSET"
else
  # `2>/dev/null` BEFORE the input redirection: redirections are applied left to
  # right, so with `< "$LOG" 2>/dev/null` the shell reports the missing file on
  # the real stderr before the silencer is in place. A dispatch that fails
  # before its first log write then emits a raw "No such file" next to the
  # explanation, and the raw half is the confusing one.
  BASE_BYTES="$(wc -c 2>/dev/null < "$LOG" | tr -d ' ')"
  BASE_BYTES="${BASE_BYTES:-0}"
  case "$BASE_BYTES" in *[!0-9]*) BASE_BYTES=0 ;; esac
fi

# Poll the worker, not the log: pid death is the one signal that fires on
# BOTH success (reply appended, then exit) and post-READY failure (nothing
# appended). Bounded: CC_DETACH_WATCH_TIMEOUT seconds (default 2700 = 45min,
# past any realistic review/plan dispatch).
TIMEOUT="${CC_DETACH_WATCH_TIMEOUT:-2700}"
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=2700 ;; esac
# Same length bound as dispatch.sh: an oversized value makes `[ -ge ]` error
# on every poll, so the watcher never times out and never hands off.
[ "${#TIMEOUT}" -le 6 ] || TIMEOUT=2700
WAITED=0
while kill -0 "$PID" 2>/dev/null; do
  if [ "$WAITED" -ge "$TIMEOUT" ]; then
    echo "TIMEOUT: detached dispatch (thread $THREAD, pid $PID) still running after ${TIMEOUT}s — it keeps running; re-watch or poll $LOG manually."
    [ "$PORCELAIN" = "1" ] && exit 20
    exit 3
  fi
  sleep 2
  WAITED=$((WAITED + 2))
done

# Worker is gone. Current log size for the delta prints below.
CUR_BYTES="$(wc -c 2>/dev/null < "$LOG" | tr -d ' ')"
CUR_BYTES="${CUR_BYTES:-0}"
case "$CUR_BYTES" in *[!0-9]*) CUR_BYTES=0 ;; esac

print_delta() { # the log bytes this dispatch appended (rotation-aware)
  if [ "$CUR_BYTES" -gt "$BASE_BYTES" ]; then
    tail -c "+$((BASE_BYTES + 1))" "$LOG" 2>/dev/null
  elif [ "$CUR_BYTES" -lt "$BASE_BYTES" ] && [ "$CUR_BYTES" -gt 0 ]; then
    # Rotation happened mid-dispatch — the newest entry is still in the
    # current .log (rotation precedes append).
    echo "(log rotated mid-run — current tail)"
    tail -c 65536 "$LOG" 2>/dev/null
  fi
}
print_warnings() { # a successful run's stderr — warnings worth surfacing
  if [ -s "$ERRS" ]; then
    echo "--- worker warnings ($ERRS):"
    tail -c 4096 "$ERRS" 2>/dev/null
  fi
}
print_diags() {
  if [ -s "$DIAG" ]; then
    echo "--- last-error tail ($DIAG):"
    tail -c 4096 "$DIAG" 2>/dev/null
  fi
  if [ -s "$ERRS" ]; then
    echo "--- worker stderr tail ($ERRS):"
    tail -c 4096 "$ERRS" 2>/dev/null
  fi
  if [ -s "$SIDE" ]; then
    echo "--- raw child stdout tail ($SIDE):"
    tail -c 4096 "$SIDE" 2>/dev/null
  fi
}

# Authoritative verdict: the worker publishes its REAL exit status to
# <thread>.detach-status (atomic, EXIT trap). Log growth alone is NOT
# success — a strict-mutation dispatch (exit 5) appends the exchange and
# still fails, and a partial append before a nonzero death looks identical.
STATUS_FILE="$STATE_DIR/$THREAD.detach-status"
S_PID="$(sed -n 's/^pid=//p' "$STATUS_FILE" 2>/dev/null | head -1)"
S_RC="$(sed -n 's/^rc=//p' "$STATUS_FILE" 2>/dev/null | head -1)"
if [ "$S_PID" = "$PID" ]; then
  case "$S_RC" in
    0)
      echo "DONE: detached dispatch on thread $THREAD finished (worker rc=0) — reply captured in $SIDE:"
      cat "$SIDE" 2>/dev/null >&3 || true
      print_warnings
      exit 0 ;;
    [0-9]*)
      echo "FAILED: detached dispatch on thread $THREAD (pid $PID) exited rc=$S_RC (5=tracked-file mutation under strict mode, 3=codex exec failed, 4=resume failed — see the driver's exit-code table)."
      if [ "$CUR_BYTES" -ne "$BASE_BYTES" ]; then
        echo "--- log delta this dispatch appended (present despite the failure):"
        print_delta
      fi
      print_diags
      # The worker's own status, so a caller can still tell a resume failure
      # from a mutation refusal; 1 for the human-facing default.
      [ "$PORCELAIN" = "1" ] && exit "$S_RC"
      exit 1 ;;
  esac
fi

# No status record matching this PID: the worker was SIGKILL'd before its
# EXIT trap, the write failed, or a NEWER launch already replaced the record.
# Log growth is deliberately NOT read as success here — a strict-mutation
# exchange followed by SIGKILL grows the log and still failed. Report
# UNKNOWN (nonzero) with everything we have; the caller decides.
echo "UNKNOWN: detached dispatch on thread $THREAD (pid $PID) left no matching status record — outcome unconfirmed (treat as failure until verified)."
if [ "$CUR_BYTES" -ne "$BASE_BYTES" ]; then
  echo "--- log delta since the given offset (outcome still unconfirmed):"
  print_delta
fi
# A pid mismatch can mean a NEWER launch replaced the record — in that case
# the canonical sidecars below belong to that newer launch, not to pid $PID.
echo "note: the sidecar tails below are the thread's LATEST launch state and may not belong to pid $PID:"
print_diags
[ "$PORCELAIN" = "1" ] && exit 21
exit 4
