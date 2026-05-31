#!/usr/bin/env bash
# cc-codex-triage — thread driver.
#
# Sends a prompt to a NAMED Codex thread. First call creates the thread via
# `codex exec` and persists the session UUID; subsequent calls resume the same
# thread via `codex exec resume <UUID>` so Codex retains full conversation
# memory across turns.
#
# Usage:
#   codex-thread.sh <thread-name> [--new]
#       Reads prompt from stdin. Echoes the assistant's final message to stdout.
#       --new forces a fresh exec, discarding the existing thread.
#
# Storage:
#   .claude/codex-threads/<thread>.id     — UUID of the active session.
#   .claude/codex-threads/<thread>.log    — append-only audit log of prompts/replies.
#
# Exit codes:
#   0   success
#   1   usage error
#   2   codex CLI missing
#   3   codex exec failed (initial)
#   4   codex exec resume failed (warns instead of silent fresh — preserves the
#       caller's memory by NOT clobbering the saved UUID).
#   5   tracked-file mutation detected pre/post codex dispatch (workspace-write
#       contamination guard, adapted from dementev-dev/adversarial-review).

set -euo pipefail

# ── args ──────────────────────────────────────────────────────────────────
FORCE_NEW=false
THREAD=""
while (( $# )); do
  case "$1" in
    --new) FORCE_NEW=true; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      if [[ -z "$THREAD" ]]; then THREAD="$1"; shift
      else echo "unknown arg: $1" >&2; exit 1
      fi ;;
  esac
done

[[ -z "$THREAD" ]] && { echo "usage: codex-thread.sh <thread-name> [--new]" >&2; exit 1; }
[[ "$THREAD" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "thread name must be [a-zA-Z0-9_.-]+" >&2; exit 1; }

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH. Install: npm install -g @openai/codex" >&2
  exit 2
}

# ── paths ─────────────────────────────────────────────────────────────────
STATE_DIR=".claude/codex-threads"
mkdir -p "$STATE_DIR"
ID_FILE="$STATE_DIR/${THREAD}.id"
LOG_FILE="$STATE_DIR/${THREAD}.log"
OUT_FILE="$(mktemp -t "cc-codex-${THREAD}-XXXXXX")"
JSONL_FILE="${OUT_FILE}.jsonl"
trap 'rm -f "$OUT_FILE" "$JSONL_FILE"' EXIT

# ── read prompt from stdin ────────────────────────────────────────────────
PROMPT="$(cat)"
[[ -z "$PROMPT" ]] && { echo "empty prompt on stdin" >&2; exit 1; }

# ── force-new ─────────────────────────────────────────────────────────────
if $FORCE_NEW; then
  rm -f "$ID_FILE"
  echo "[$(date -u +%FT%TZ)] --new: dropped previous thread" >> "$LOG_FILE"
fi

# ── tracked-file mutation guard (pre) ─────────────────────────────────────
REPO_ROOT="$(git -C . rev-parse --show-toplevel 2>/dev/null || true)"
PRE_PORCELAIN=""
if [[ -n "$REPO_ROOT" ]]; then
  PRE_PORCELAIN="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)"
fi

# ── dispatch ──────────────────────────────────────────────────────────────
MODE=""
if [[ -s "$ID_FILE" ]]; then
  SID="$(cat "$ID_FILE")"
  MODE="resume($SID)"
  if ! codex exec resume --json "$SID" \
        -o "$OUT_FILE" \
        - <<< "$PROMPT" \
        > "$JSONL_FILE" 2>&1; then
    echo "codex exec resume FAILED for thread '$THREAD' (session=$SID)." >&2
    echo "Possible causes: session expired/deleted, codex CLI upgrade broke wire format, or model unavailable." >&2
    echo "The saved UUID has NOT been cleared — re-run with --new to start a fresh thread (loses memory)," >&2
    echo "or inspect $JSONL_FILE for details." >&2
    exit 4
  fi
else
  MODE="initial"
  # Use the user's configured default model/sandbox by NOT overriding -m/-s.
  # Override env CC_CODEX_FLAGS to customise (e.g. CC_CODEX_FLAGS="-m gpt-5.5 -s read-only").
  read -r -a EXTRA_FLAGS <<< "${CC_CODEX_FLAGS:-}"
  if ! codex exec --json "${EXTRA_FLAGS[@]}" \
        -o "$OUT_FILE" \
        - <<< "$PROMPT" \
        > "$JSONL_FILE" 2>&1; then
    echo "codex exec FAILED (initial). See $JSONL_FILE." >&2
    exit 3
  fi
  # Extract thread_id from the JSONL stream. The first event with a
  # thread_id / session_id / conversation_id field is the canonical one.
  SID="$(awk '
    /"thread_id"/      { match($0, /"thread_id" *: *"[0-9a-f-]+"/);     if (RSTART) { print substr($0, RSTART+13, RLENGTH-14); exit } }
    /"session_id"/     { match($0, /"session_id" *: *"[0-9a-f-]+"/);    if (RSTART) { print substr($0, RSTART+14, RLENGTH-15); exit } }
    /"conversation_id"/{ match($0, /"conversation_id" *: *"[0-9a-f-]+"/); if (RSTART) { print substr($0, RSTART+19, RLENGTH-20); exit } }
  ' "$JSONL_FILE")"
  if [[ -n "$SID" && "$SID" =~ ^[0-9a-f-]{16,}$ ]]; then
    echo "$SID" > "$ID_FILE"
  else
    echo "WARN: could not extract session UUID from codex --json output for thread '$THREAD'." >&2
    echo "The thread will NOT persist — next invocation will start fresh." >&2
    echo "If your codex CLI uses a non-standard event schema, file an issue with the first 20 lines of:" >&2
    echo "  $JSONL_FILE" >&2
  fi
fi

# ── tracked-file mutation guard (post) ────────────────────────────────────
if [[ -n "$REPO_ROOT" ]]; then
  POST_PORCELAIN="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)"
  if [[ "$PRE_PORCELAIN" != "$POST_PORCELAIN" ]]; then
    echo "WARN: tracked-file status changed during codex dispatch ($MODE)." >&2
    echo "Diff (pre vs post):" >&2
    diff <(echo "$PRE_PORCELAIN") <(echo "$POST_PORCELAIN") >&2 || true
    echo "Codex was likely run with a writable sandbox. Inspect the working tree before continuing." >&2
    # Non-fatal warning by default — set CC_CODEX_TRIAGE_STRICT=1 to fail.
    [[ "${CC_CODEX_TRIAGE_STRICT:-0}" == "1" ]] && exit 5
  fi
fi

# ── audit log + final message to stdout ───────────────────────────────────
{
  echo "[$(date -u +%FT%TZ)] mode=$MODE thread=$THREAD"
  echo "PROMPT:"; sed 's/^/  /' <<< "$PROMPT"
  echo "REPLY:"; sed 's/^/  /' "$OUT_FILE"
  echo "---"
} >> "$LOG_FILE"

cat "$OUT_FILE"
