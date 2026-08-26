#!/usr/bin/env bash
# Read-only summary of the current worktree's Codex threads and required review.
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/lib.sh"

if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
    || [ -z "$ROOT" ]; then
  echo "Not inside a git repository — no thread state to report."
  exit 0
fi
cd "$ROOT" || exit 0
STATE_DIR="$(bash "$SELF_DIR/state-dir.sh" --read-only)" || exit $?
VERDICT_SH="$SELF_DIR/verdict.sh"
REQUIRED_CODEX="0.137.0"

field_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
last_verdict() {
  _value="$(bash "$VERDICT_SH" informational "$STATE_DIR/$1.log" 0 2>/dev/null)"
  printf '%s' "${_value:--}"
}

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
{ [ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ]; } || BRANCH="(detached or unborn HEAD)"
CHANGES="$(git status --porcelain -uall 2>/dev/null | grep -c . | tr -d ' ')"

echo "cc-codex-triage status"
echo "  repo branch : $BRANCH"
echo "  working tree: ${CHANGES:-0} change(s)"
echo "  state dir   : $STATE_DIR (current worktree)"

if command -v codex >/dev/null 2>&1; then
  RAW="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' | head -1)"
  CORE="${RAW%%-*}"
  if [ -z "$CORE" ]; then
    echo "  codex CLI   : present (version unknown)"
  elif [ "$(printf '%s\n%s\n' "$CORE" "$REQUIRED_CODEX" | sort -V | head -1)" = "$CORE" ] \
      && [ "$CORE" != "$REQUIRED_CODEX" ]; then
    echo "  codex CLI   : $RAW  WARNING below required >= $REQUIRED_CODEX"
  else
    echo "  codex CLI   : $RAW"
  fi
else
  echo "  codex CLI   : NOT FOUND on PATH"
fi

echo
echo "Threads:"
ANY=0
for ID_FILE in "$STATE_DIR"/*.id; do
  [ -f "$ID_FILE" ] || continue
  ANY=1
  NAME="$(basename "$ID_FILE" .id)"
  ROUNDS="$(cat "$STATE_DIR/$NAME.rounds" 2>/dev/null || echo 0)"
  SIZE="$(wc -c < "$STATE_DIR/$NAME.log" 2>/dev/null | tr -d ' ')"
  VERDICT="$(last_verdict "$NAME")"
  printf '  %-30s rounds=%-3s size=%-8s last=%-16s verdict=%s\n' \
    "$NAME" "$ROUNDS" "${SIZE:-0}" "$(_mtime "$ID_FILE")" "$VERDICT"
done
[ "$ANY" = 1 ] || echo "  (none)"

echo
echo "Required review:"
ANY=0
for STATE_FILE in "$STATE_DIR"/*.review-state; do
  [ -f "$STATE_FILE" ] || continue
  ANY=1
  NAME="$(basename "$STATE_FILE" .review-state)"
  STATUS="$(field_value "$STATE_FILE" status)"
  ELIGIBLE="$(field_value "$STATE_FILE" gate_eligible)"
  VERDICT="$(field_value "$STATE_FILE" verdict)"
  printf '  %-30s status=%-22s gate_eligible=%-5s verdict=%s\n' \
    "$NAME" "${STATUS:-?}" "${ELIGIBLE:-?}" "${VERDICT:--}"
  case "$STATUS" in
    APPROVED) echo "      authoritative check: review-state.sh check $NAME" ;;
    CAP_REACHED) echo "      hard stop — reset only after a user decision" ;;
    PENDING) echo "      one required-review round is claimed" ;;
  esac
done
[ "$ANY" = 1 ] || echo "  (none)"
