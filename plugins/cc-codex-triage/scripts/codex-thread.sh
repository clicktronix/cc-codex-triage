#!/usr/bin/env bash
# cc-codex-triage — thread driver.
#
# Sends a prompt to a NAMED Codex thread. First call creates the thread via
# `codex exec` and persists the session UUID; subsequent calls resume the same
# thread via `codex exec resume <UUID>` so Codex retains full conversation
# memory across turns.
#
# Usage:
#   codex-thread.sh <thread-name> [--new | --oneshot]
#       Reads prompt from stdin. Echoes the assistant's final message to stdout.
#       --new      forces a fresh persistent thread, discarding the existing one.
#       --oneshot  throwaway: ignores thread state entirely, runs an ephemeral
#                  exec (no .id written, no rollout persisted on the Codex side).
#                  Mutually exclusive with --new.
#
# Storage:
#   .claude/codex-threads/<thread>.id     — UUID of the active session.
#   .claude/codex-threads/<thread>.log    — append-only audit log of prompts/replies.
#
# Exit codes:
#   0   success
#   1   usage error
#   2   codex CLI missing
#   3   codex exec failed (initial or oneshot)
#   4   codex exec resume failed (warns instead of silent fresh — preserves the
#       caller's memory by NOT clobbering the saved UUID).
#   5   tracked-file mutation detected pre/post codex dispatch (workspace-write
#       contamination guard, adapted from dementev-dev/adversarial-review).

set -euo pipefail

# ── args ──────────────────────────────────────────────────────────────────
FORCE_NEW=false
ONESHOT=false
THREAD=""
while (( $# )); do
  case "$1" in
    --new) FORCE_NEW=true; shift ;;
    --oneshot) ONESHOT=true; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      if [[ -z "$THREAD" ]]; then THREAD="$1"; shift
      else echo "unknown arg: $1" >&2; exit 1
      fi ;;
  esac
done

[[ -z "$THREAD" ]] && { echo "usage: codex-thread.sh <thread-name> [--new | --oneshot]" >&2; exit 1; }
[[ "$THREAD" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "thread name must be [a-zA-Z0-9_.-]+" >&2; exit 1; }
if $FORCE_NEW && $ONESHOT; then
  echo "--new and --oneshot are mutually exclusive (--new resets a persistent thread; --oneshot keeps none)." >&2
  exit 1
fi

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH. Install: npm install -g @openai/codex" >&2
  exit 2
}

# ── paths ─────────────────────────────────────────────────────────────────
STATE_DIR=".claude/codex-threads"
mkdir -p "$STATE_DIR"
ID_FILE="$STATE_DIR/${THREAD}.id"
LOG_FILE="$STATE_DIR/${THREAD}.log"
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/cc-codex-${THREAD}.XXXXXX")"
JSONL_FILE="${OUT_FILE}.jsonl"
trap 'rm -f "$OUT_FILE" "$JSONL_FILE"' EXIT
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

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
SID=""
if ! $ONESHOT && [[ -s "$ID_FILE" ]]; then
  SID="$(cat "$ID_FILE")"
  if ! [[ "$SID" =~ $UUID_RE ]]; then
    echo "WARN: saved session ID in $ID_FILE is not a valid UUID ('$SID'). Discarding and starting fresh." >&2
    rm -f "$ID_FILE"
    SID=""
  fi
fi

if $ONESHOT; then
  MODE="oneshot"
  # Throwaway: no thread tracking, no rollout persisted on the Codex side.
  # codex exec resume cannot continue an --ephemeral session — that is the point.
  CWD_FOR_CODEX="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  read -r -a EXTRA_FLAGS <<< "${CC_CODEX_FLAGS:-}"
  if ! codex exec --json --ephemeral -C "$CWD_FOR_CODEX" "${EXTRA_FLAGS[@]}" \
        -o "$OUT_FILE" \
        - <<< "$PROMPT" \
        > "$JSONL_FILE" 2>&1; then
    echo "codex exec FAILED (oneshot). See $JSONL_FILE." >&2
    exit 3
  fi
elif [[ -n "$SID" ]]; then
  MODE="resume($SID)"
  # codex exec resume does NOT accept -C/-s/-m/-c (session-immutable).
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
  # Pin cwd explicitly via -C so initial dispatch isn't sensitive to who launches the script.
  # codex exec resume cannot accept -C; cwd is fixed at session creation.
  CWD_FOR_CODEX="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  # Use the user's configured default model/sandbox by NOT overriding -m/-s here.
  # Override env CC_CODEX_FLAGS to customise (e.g. CC_CODEX_FLAGS="-m gpt-5.5 -s read-only").
  read -r -a EXTRA_FLAGS <<< "${CC_CODEX_FLAGS:-}"
  if ! codex exec --json -C "$CWD_FOR_CODEX" "${EXTRA_FLAGS[@]}" \
        -o "$OUT_FILE" \
        - <<< "$PROMPT" \
        > "$JSONL_FILE" 2>&1; then
    echo "codex exec FAILED (initial). See $JSONL_FILE." >&2
    exit 3
  fi
  # Extract the session UUID from the JSONL stream. The first event with a
  # thread_id / session_id / conversation_id field is the canonical one.
  # Strict UUID v4 shape (8-4-4-4-12) — refuse garbage to avoid pinning the
  # thread to an unusable identifier.
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

# ── audit log (with size cap) + final message to stdout ───────────────────
{
  echo "[$(date -u +%FT%TZ)] mode=$MODE thread=$THREAD"
  echo "PROMPT:"; sed 's/^/  /' <<< "$PROMPT"
  echo "REPLY:"; sed 's/^/  /' "$OUT_FILE"
  echo "---"
} >> "$LOG_FILE"

# Rotate audit log when it exceeds ~1MB. Keep one .1 backup for one round.
LOG_CAP_BYTES="${CC_CODEX_TRIAGE_LOG_CAP_BYTES:-1048576}"
if [[ -f "$LOG_FILE" ]]; then
  LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  if [[ -n "$LOG_SIZE" && "$LOG_SIZE" -gt "$LOG_CAP_BYTES" ]]; then
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
  fi
fi

cat "$OUT_FILE"
