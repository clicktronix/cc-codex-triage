#!/usr/bin/env bash
# cc-codex-triage — thread driver.
#
# Sends a prompt to a NAMED Codex thread. First call creates the thread via
# `codex exec` and persists the session UUID; subsequent calls resume the same
# thread via `codex exec resume <UUID>` so Codex retains full conversation
# memory across turns.
#
# Usage:
#   codex-thread.sh <thread-name> [--new | --oneshot] [--require-existing]
#       Reads prompt from stdin. Echoes the assistant's final message to stdout.
#       --new               fresh persistent thread, discarding the existing one.
#       --oneshot           throwaway: ignores thread state, runs an ephemeral
#                           exec (no .id, no rollout, no audit log). Mutually
#                           exclusive with --new.
#       --require-existing  fail (exit 6) instead of creating a new thread when
#                           none exists. Used by /reply.
#
# Storage (under .claude/codex-threads/ — git-ignore this directory):
#   <thread>.id               UUID of the active session.
#   <thread>.log              append-only audit log (rotated at ~1 MB to .log.1).
#   <thread>.last-error.jsonl raw Codex JSONL from the most recent failure.
#
# Exit codes:
#   0   success
#   1   usage error
#   2   codex CLI missing
#   3   codex exec failed (initial or oneshot)
#   4   codex exec resume failed (saved UUID preserved — re-run with --new)
#   5   tracked-file mutation detected (only with CC_CODEX_TRIAGE_STRICT=1)
#   6   --require-existing set but no existing thread

set -euo pipefail

# ── args ──────────────────────────────────────────────────────────────────
FORCE_NEW=false
ONESHOT=false
REQUIRE_EXISTING=false
THREAD=""
while (( $# )); do
  case "$1" in
    --new) FORCE_NEW=true; shift ;;
    --oneshot) ONESHOT=true; shift ;;
    --require-existing) REQUIRE_EXISTING=true; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      if [[ -z "$THREAD" ]]; then THREAD="$1"; shift
      else echo "unknown arg: $1" >&2; exit 1
      fi ;;
  esac
done

[[ -z "$THREAD" ]] && { echo "usage: codex-thread.sh <thread-name> [--new | --oneshot] [--require-existing]" >&2; exit 1; }
[[ "$THREAD" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "thread name must be [a-zA-Z0-9_.-]+" >&2; exit 1; }
if $FORCE_NEW && $ONESHOT; then
  echo "--new and --oneshot are mutually exclusive (--new resets a persistent thread; --oneshot keeps none)." >&2
  exit 1
fi
if $ONESHOT && $REQUIRE_EXISTING; then
  echo "--oneshot and --require-existing are mutually exclusive (oneshot keeps no thread to require)." >&2
  exit 1
fi

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH. Install: npm install -g @openai/codex" >&2
  exit 2
}

# ── paths ─────────────────────────────────────────────────────────────────
STATE_DIR=".claude/codex-threads"
# Create the state dir only for persistent modes. --oneshot leaves no trace in
# the repo, so it must not even create an empty directory; its failure diag goes
# to a temp path instead.
ID_FILE="$STATE_DIR/${THREAD}.id"
LOG_FILE="$STATE_DIR/${THREAD}.log"
if $ONESHOT; then
  DIAG_FILE="${TMPDIR:-/tmp}/cc-codex-${THREAD}.last-error.jsonl"
else
  mkdir -p "$STATE_DIR"
  DIAG_FILE="$STATE_DIR/${THREAD}.last-error.jsonl"
fi
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/cc-codex-${THREAD}.XXXXXX")"
JSONL_FILE="${OUT_FILE}.jsonl"
trap 'rm -f "$OUT_FILE" "$JSONL_FILE"' EXIT
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Preserve the raw Codex stream to a stable path before dying, so the path we
# point the user at still exists after the EXIT trap removes the temp file.
fail_with_diag() {
  local code="$1"; shift
  cp -f "$JSONL_FILE" "$DIAG_FILE" 2>/dev/null || true
  printf '%s\n' "$@" >&2
  echo "Diagnostics saved to: $DIAG_FILE" >&2
  exit "$code"
}

# Build the codex flag array from CC_CODEX_FLAGS. Empty is fine — the
# `${arr[@]+...}` guard keeps `set -u` happy on bash 3.2 (macOS default),
# where expanding an empty array directly is an "unbound variable" error.
read -r -a EXTRA_FLAGS <<< "${CC_CODEX_FLAGS:-}"

# ── read prompt from stdin ────────────────────────────────────────────────
PROMPT="$(cat)"
[[ -z "$PROMPT" ]] && { echo "empty prompt on stdin" >&2; exit 1; }

# ── force-new ─────────────────────────────────────────────────────────────
if $FORCE_NEW; then
  rm -f "$ID_FILE"
fi

# Porcelain status with our own state dir filtered out — its .id/.log churn is
# not a "tracked-file mutation" and would otherwise false-positive the guard.
porcelain() {
  [[ -n "$REPO_ROOT" ]] || return 0
  # -uall lists untracked files individually; without it git collapses a new
  # untracked dir to "?? .claude/" and our own state writes leak past the filter.
  git -C "$REPO_ROOT" status --porcelain -uall 2>/dev/null | grep -vF '.claude/codex-threads/' || true
}

# ── tracked-file mutation guard (pre) ─────────────────────────────────────
REPO_ROOT="$(git -C . rev-parse --show-toplevel 2>/dev/null || true)"
PRE_PORCELAIN="$(porcelain)"

# ── resolve thread ─────────────────────────────────────────────────────────
MODE=""
SID=""
if ! $ONESHOT && [[ -s "$ID_FILE" ]]; then
  SID="$(cat "$ID_FILE")"
  if ! [[ "$SID" =~ $UUID_RE ]]; then
    echo "WARN: saved session ID in $ID_FILE is not a valid UUID ('$SID'). Discarding and starting fresh." >&2
    rm -f "$ID_FILE"
    SID=""
  fi
fi

if $REQUIRE_EXISTING && [[ -z "$SID" ]]; then
  echo "No existing thread '$THREAD' (.claude/codex-threads/${THREAD}.id not found or invalid)." >&2
  echo "--require-existing refuses to create one. Start a thread first with /ask, /review, /plan, or /thread." >&2
  exit 6
fi

# ── dispatch ──────────────────────────────────────────────────────────────
if $ONESHOT; then
  MODE="oneshot"
  # Throwaway: no thread tracking, no rollout persisted on the Codex side.
  # codex exec resume cannot continue an --ephemeral session — that is the point.
  CWD_FOR_CODEX="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  if ! codex exec --json --ephemeral -C "$CWD_FOR_CODEX" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        -o "$OUT_FILE" - <<< "$PROMPT" > "$JSONL_FILE" 2>&1; then
    fail_with_diag 3 "codex exec FAILED (oneshot)."
  fi
elif [[ -n "$SID" ]]; then
  MODE="resume($SID)"
  # No overrides on resume: -s (sandbox) and -C (cwd) are fixed at session
  # creation and resume does not take them; -m/-c are accepted by newer codex
  # CLIs but we deliberately omit them to keep the thread's model/config stable.
  if ! codex exec resume --json "$SID" \
        -o "$OUT_FILE" - <<< "$PROMPT" > "$JSONL_FILE" 2>&1; then
    fail_with_diag 4 \
      "codex exec resume FAILED for thread '$THREAD' (session=$SID)." \
      "Possible causes: session expired/deleted, codex CLI upgrade broke wire format, or model unavailable." \
      "The saved UUID has NOT been cleared — re-run with --new to start a fresh thread (loses memory)."
  fi
else
  MODE="initial"
  # Pin cwd via -C so initial dispatch isn't sensitive to who launches the script.
  CWD_FOR_CODEX="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  if ! codex exec --json -C "$CWD_FOR_CODEX" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        -o "$OUT_FILE" - <<< "$PROMPT" > "$JSONL_FILE" 2>&1; then
    fail_with_diag 3 "codex exec FAILED (initial)."
  fi
  # Extract the session UUID from the JSONL stream. First event carrying a
  # thread_id / session_id / conversation_id wins. Strict UUID shape only.
  SID="$(awk '
    /"thread_id"/      { match($0, /"thread_id" *: *"[0-9a-f-]+"/);     if (RSTART) { print substr($0, RSTART+13, RLENGTH-14); exit } }
    /"session_id"/     { match($0, /"session_id" *: *"[0-9a-f-]+"/);    if (RSTART) { print substr($0, RSTART+14, RLENGTH-15); exit } }
    /"conversation_id"/{ match($0, /"conversation_id" *: *"[0-9a-f-]+"/); if (RSTART) { print substr($0, RSTART+19, RLENGTH-20); exit } }
  ' "$JSONL_FILE")"
  if [[ -n "$SID" && "$SID" =~ $UUID_RE ]]; then
    echo "$SID" > "$ID_FILE"
  else
    echo "WARN: could not extract a valid UUID from codex --json output for thread '$THREAD' (got: '$SID')." >&2
    echo "The thread will NOT persist — next invocation will start fresh." >&2
    cp -f "$JSONL_FILE" "$DIAG_FILE" 2>/dev/null || true
    echo "Raw stream saved to: $DIAG_FILE (file an issue if your codex CLI uses a non-standard event schema)." >&2
  fi
fi

# ── tracked-file mutation guard (post) ────────────────────────────────────
# Limitation: git status --porcelain only detects status TRANSITIONS. If a file
# was already dirty before the dispatch and Codex changes its content further,
# the porcelain line is unchanged and this guard will not fire. Commit/stash WIP
# or use CC_CODEX_FLAGS="-s read-only" for stronger protection.
if [[ -n "$REPO_ROOT" ]]; then
  POST_PORCELAIN="$(porcelain)"
  if [[ "$PRE_PORCELAIN" != "$POST_PORCELAIN" ]]; then
    echo "WARN: tracked-file status changed during codex dispatch ($MODE)." >&2
    echo "Diff (pre vs post):" >&2
    diff <(echo "$PRE_PORCELAIN") <(echo "$POST_PORCELAIN") >&2 || true
    echo "Codex was likely run with a writable sandbox. Inspect the working tree before continuing." >&2
    [[ "${CC_CODEX_TRIAGE_STRICT:-0}" == "1" ]] && exit 5
  fi
fi

# ── audit log (skipped for --oneshot to keep it traceless) ────────────────
if ! $ONESHOT; then
  # Rotate BEFORE appending so the newest entry always lands in the current
  # .log (a post-append rotation would move the just-written entry to .log.1
  # and leave /reply unable to find the last REPLY).
  LOG_CAP_BYTES="${CC_CODEX_TRIAGE_LOG_CAP_BYTES:-1048576}"
  if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
    if [[ -n "$LOG_SIZE" && "$LOG_SIZE" -gt "$LOG_CAP_BYTES" ]]; then
      mv -f "$LOG_FILE" "${LOG_FILE}.1"
    fi
  fi
  {
    echo "[$(date -u +%FT%TZ)] mode=$MODE thread=$THREAD"
    echo "PROMPT:"; sed 's/^/  /' <<< "$PROMPT"
    echo "REPLY:"; sed 's/^/  /' "$OUT_FILE"
    echo "---"
  } >> "$LOG_FILE"
fi

cat "$OUT_FILE"
