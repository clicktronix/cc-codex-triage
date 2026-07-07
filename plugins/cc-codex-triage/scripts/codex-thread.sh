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
#   <thread>.rounds           successful-dispatch counter (reset by --new).
#   <thread>.last-error.jsonl raw Codex JSONL from the most recent failure.
#   <thread>.findings.jsonl   /review's findings ledger (per-task; reset by --new).
#   <thread>.scope            /review's pinned scope (per-task; reset by --new).
#   <thread>.approved         /review's last-APPROVE baseline (per-task; reset by --new).
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
MODEL=""
EFFORT=""
SCHEMA=""
while (( $# )); do
  case "$1" in
    --new) FORCE_NEW=true; shift ;;
    --oneshot) ONESHOT=true; shift ;;
    --require-existing) REQUIRE_EXISTING=true; shift ;;
    --model)  [[ $# -ge 2 ]] || { echo "--model needs a value" >&2; exit 1; }; MODEL="$2"; shift 2 ;;
    --effort) [[ $# -ge 2 ]] || { echo "--effort needs a value" >&2; exit 1; }; EFFORT="$2"; shift 2 ;;
    --schema) [[ $# -ge 2 ]] || { echo "--schema needs a value" >&2; exit 1; }; SCHEMA="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)
      # A mistyped flag must not silently become a thread name (and burn a
      # dispatch on it) — the thread-name regex would otherwise accept it.
      echo "unknown flag: $1" >&2; exit 1 ;;
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
if $FORCE_NEW && $REQUIRE_EXISTING; then
  # Order matters: --new deletes the saved UUID before --require-existing is
  # checked — allowing the combo would destroy the very thread it then refuses
  # to use. Refuse up front instead.
  echo "--new and --require-existing are mutually exclusive (--new would discard the thread --require-existing demands)." >&2
  exit 1
fi
if [[ -n "$EFFORT" ]]; then
  case "$EFFORT" in none|minimal|low|medium|high|xhigh) ;; *)
    echo "--effort must be none|minimal|low|medium|high|xhigh" >&2; exit 1 ;;
  esac
fi
[[ -z "$SCHEMA" || -f "$SCHEMA" ]] || { echo "--schema file not found: $SCHEMA" >&2; exit 1; }

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH. Install: npm install -g @openai/codex" >&2
  exit 2
}

# ── anchor cwd ────────────────────────────────────────────────────────────
# State paths are repo-relative, but the Bash tool's cwd persists across calls
# and can drift into subdirectories. Anchor to the project root so the same
# thread name always resolves to the same state files — and so the Stop hook
# (which anchors the same way) reads the directory the driver wrote.
ANCHOR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
if [[ -n "$ANCHOR" && -d "$ANCHOR" ]]; then
  cd "$ANCHOR"
fi

# ── paths ─────────────────────────────────────────────────────────────────
STATE_DIR=".claude/codex-threads"
# Create the state dir only for persistent modes. --oneshot leaves no trace in
# the repo, so it must not even create an empty directory; its failure diag goes
# to a temp path instead.
ID_FILE="$STATE_DIR/${THREAD}.id"
LOG_FILE="$STATE_DIR/${THREAD}.log"
ROUNDS_FILE="$STATE_DIR/${THREAD}.rounds"
# Per-task sidecars written by /review (the model), not by this driver. Listed
# here so --new can reset them with the rest of the thread's state.
FINDINGS_FILE="$STATE_DIR/${THREAD}.findings.jsonl"
SCOPE_FILE="$STATE_DIR/${THREAD}.scope"
APPROVED_FILE="$STATE_DIR/${THREAD}.approved"
if $ONESHOT; then
  DIAG_FILE="${TMPDIR:-/tmp}/cc-codex-${THREAD}.last-error.jsonl"
else
  mkdir -p "$STATE_DIR"
  DIAG_FILE="$STATE_DIR/${THREAD}.last-error.jsonl"
  # One-time hygiene nudge: thread state should never be committed. Warn once
  # per repo (marker file suppresses repeats), only when inside a git repo.
  if git -C . rev-parse --show-toplevel >/dev/null 2>&1 \
     && ! git -C . check-ignore -q "$STATE_DIR/x" 2>/dev/null \
     && [[ ! -f "$STATE_DIR/.gitignore-warned" ]]; then
    echo "HINT: $STATE_DIR is not gitignored — add '.claude/codex-threads/' to .gitignore (these are transient session logs; a 'git add -A' would stage them)." >&2
    touch "$STATE_DIR/.gitignore-warned"
  fi
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

# model/effort: initial/oneshot ONLY (kept stable across the thread; WARN if passed
# on resume). schema: a per-MESSAGE output shape — `codex exec resume` accepts
# --output-schema, so it applies on EVERY path (initial, oneshot, AND resume).
OVERRIDES=()
[[ -n "$MODEL"  ]] && OVERRIDES+=( -m "$MODEL" )
[[ -n "$EFFORT" ]] && OVERRIDES+=( -c "model_reasoning_effort=$EFFORT" )
SCHEMA_ARGS=()
[[ -n "$SCHEMA" ]] && SCHEMA_ARGS+=( --output-schema "$SCHEMA" )

# ── read prompt from stdin ────────────────────────────────────────────────
PROMPT="$(cat)"
[[ -z "$PROMPT" ]] && { echo "empty prompt on stdin" >&2; exit 1; }

# ── force-new ─────────────────────────────────────────────────────────────
if $FORCE_NEW; then
  # Reset the per-task sidecars too, so a reused thread name does not inherit
  # the previous task's findings ledger / scope / approval baseline.
  rm -f "$ID_FILE" "$ROUNDS_FILE" "$FINDINGS_FILE" "$SCOPE_FILE" "$APPROVED_FILE"
fi

# Porcelain status with our own state dir filtered out — its .id/.log churn is
# not a "tracked-file mutation" and would otherwise false-positive the guard.
porcelain() {
  [[ -n "$REPO_ROOT" ]] || return 0
  # -uall lists untracked files individually; without it git collapses a new
  # untracked dir to "?? .claude/" and our own state writes leak past the filter.
  local out
  if ! out="$(git -C "$REPO_ROOT" status --porcelain -uall 2>/dev/null)"; then
    # A transient git failure (e.g. another process holding index.lock) must
    # not masquerade as an empty status — that would false-positive the guard
    # (fatal under CC_CODEX_TRIAGE_STRICT=1). Emit a sentinel; the guard skips
    # the comparison when either side carries it.
    echo "__PORCELAIN_UNAVAILABLE__"
    return 0
  fi
  printf '%s\n' "$out" | grep -vF '.claude/codex-threads/' || true
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
        ${OVERRIDES[@]+"${OVERRIDES[@]}"} ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} \
        -o "$OUT_FILE" - <<< "$PROMPT" > "$JSONL_FILE" 2>&1; then
    fail_with_diag 3 "codex exec FAILED (oneshot)."
  fi
elif [[ -n "$SID" ]]; then
  MODE="resume($SID)"
  # No model/effort overrides on resume: -s (sandbox) and -C (cwd) are fixed at
  # session creation and resume does not take them; -m/-c are accepted by newer
  # codex CLIs but we deliberately omit them to keep the thread's model/config
  # stable. --output-schema DOES apply here — it shapes this single message.
  if [[ -n "$MODEL$EFFORT" ]]; then
    echo "WARN: --model/--effort are ignored on resume (kept stable across the thread). Use --new to change them." >&2
  fi
  if ! codex exec resume --json "$SID" \
        ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} \
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
        ${OVERRIDES[@]+"${OVERRIDES[@]}"} ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} \
        -o "$OUT_FILE" - <<< "$PROMPT" > "$JSONL_FILE" 2>&1; then
    fail_with_diag 3 "codex exec FAILED (initial)."
  fi
  # Extract the session UUID from the JSONL stream. First event carrying a
  # thread_id / session_id / conversation_id wins. Two-step: match the whole
  # key:value pair (whitespace-tolerant), then strip down to the value — no
  # fixed substr offsets, so a formatting change in codex --json output (e.g.
  # a space after the colon) cannot silently break thread persistence. The
  # strict UUID shape check happens below in bash ($UUID_RE).
  SID="$(awk '
    match($0, /"(thread_id|session_id|conversation_id)"[ \t]*:[ \t]*"[0-9a-fA-F-]+"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^.*"[ \t]*:[ \t]*"/, "", s)   # drop key, colon, opening quote
      sub(/"$/, "", s)                   # drop closing quote
      print s
      exit
    }
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
STRICT_MUTATION_EXIT=false
if [[ -n "$REPO_ROOT" ]]; then
  POST_PORCELAIN="$(porcelain)"
  if [[ "$PRE_PORCELAIN" == *__PORCELAIN_UNAVAILABLE__* || "$POST_PORCELAIN" == *__PORCELAIN_UNAVAILABLE__* ]]; then
    echo "WARN: git status was unavailable for the mutation guard (pre or post) — skipping the comparison this round." >&2
  elif [[ "$PRE_PORCELAIN" != "$POST_PORCELAIN" ]]; then
    echo "WARN: tracked-file status changed during codex dispatch ($MODE)." >&2
    echo "Diff (pre vs post):" >&2
    diff <(echo "$PRE_PORCELAIN") <(echo "$POST_PORCELAIN") >&2 || true
    echo "Codex was likely run with a writable sandbox. Inspect the working tree before continuing." >&2
    # Exit 5 is deferred until AFTER the audit log append below — the one
    # exchange you most want in the log is the suspicious one.
    if [[ "${CC_CODEX_TRIAGE_STRICT:-0}" == "1" ]]; then STRICT_MUTATION_EXIT=true; fi
  fi
fi

# ── round counter + audit log (skipped for --oneshot, traceless) ──────────
if ! $ONESHOT; then
  # Round = number of successful dispatches on this PERSISTED thread. Skip the
  # bump when the thread failed to persist (no .id) — otherwise a never-resumed
  # thread accumulates rounds invisible to /thread-list, which iterates *.id.
  if [[ -s "$ID_FILE" ]]; then
    # Validate before arithmetic: a corrupted/CRLF .rounds would otherwise be
    # an arithmetic error under set -e — killing the script AFTER the paid
    # dispatch succeeded, losing the reply. Garbage resets the counter to 0.
    # Leading zeros count as garbage too: bash arithmetic parses 08 as invalid
    # octal — the exact trap the hook's is_num guards against.
    PREV_ROUNDS="$(cat "$ROUNDS_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$PREV_ROUNDS" =~ ^(0|[1-9][0-9]*)$ ]] || PREV_ROUNDS=0
    ROUND=$(( PREV_ROUNDS + 1 ))
    echo "$ROUND" > "$ROUNDS_FILE"
  else
    ROUND=0
  fi

  # Rotate BEFORE appending so the newest entry always lands in the current
  # .log (a post-append rotation would move the just-written entry to .log.1
  # and leave /reply unable to find the last REPLY).
  LOG_CAP_BYTES="${CC_CODEX_TRIAGE_LOG_CAP_BYTES:-1048576}"
  # A non-numeric (or leading-zero octal-trap) override would error inside the
  # [[ -gt ]] below and silently disable rotation forever — fall back instead.
  [[ "$LOG_CAP_BYTES" =~ ^(0|[1-9][0-9]*)$ ]] || LOG_CAP_BYTES=1048576
  if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
    if [[ -n "$LOG_SIZE" && "$LOG_SIZE" -gt "$LOG_CAP_BYTES" ]]; then
      mv -f "$LOG_FILE" "${LOG_FILE}.1"
    fi
  fi
  # Log format contract: the column-0 markers ([timestamp], PROMPT:, REPLY:,
  # ---) are load-bearing — the Stop hook's verdict parser uses them to read
  # verdicts from REPLY sections ONLY (a verdict literal inside a logged
  # PROMPT must never release the autoreview gate). Body lines are always
  # indented two spaces, so prompt/reply content cannot fake a marker.
  {
    echo "[$(date -u +%FT%TZ)] mode=$MODE thread=$THREAD round=$ROUND"
    echo "PROMPT:"; sed 's/^/  /' <<< "$PROMPT"
    echo "REPLY:"; sed 's/^/  /' "$OUT_FILE"
    echo "---"
  } >> "$LOG_FILE"
fi

if $STRICT_MUTATION_EXIT; then
  exit 5
fi

cat "$OUT_FILE"
