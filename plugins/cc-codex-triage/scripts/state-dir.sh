#!/usr/bin/env bash
# Resolve a worktree or standalone directory and its persistent state.
#
# Keep each task's conversation scoped to its worktree by policy. The driver
# explicitly passes this checkout on resume too. State is not shared implicitly
# with another checkout; retain needed history before removing a worktree.
#
# usage: state-dir.sh [--read-only|--root]
set -u
umask 077

READ_ONLY=false
ROOT_ONLY=false
case "${1:-}" in
  "") ;;
  --read-only) READ_ONLY=true ;;
  --root) ROOT_ONLY=true ;;
  *) echo "usage: state-dir.sh [--read-only|--root]" >&2; exit 1 ;;
esac

CONTEXT="${CLAUDE_PROJECT_DIR:-$PWD}"
ROOT="$(cd "$CONTEXT" 2>/dev/null && pwd -P)" \
  || { echo "invalid context directory: $CONTEXT" >&2; exit 7; }
if REPO_ROOT="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
  ROOT="$REPO_ROOT"
  GIT_DIR="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null)" || exit 7
  STATE_DIR="$GIT_DIR/cc-codex-triage/threads"
else
  $ROOT_ONLY && { printf '%s\n' "$ROOT"; exit 0; }
  STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
  case "$STATE_HOME" in /*) ;; *) echo "XDG_STATE_HOME must be absolute" >&2; exit 7 ;; esac
  CONTEXT_KEY="$(printf '%s' "$ROOT" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)" \
    || { echo "Working Python is required to resolve standalone thread state; repair python3 on PATH and retry." >&2; exit 2; }
  STATE_DIR="$STATE_HOME/cc-codex-triage/contexts/$CONTEXT_KEY/threads"
fi
$ROOT_ONLY && { printf '%s\n' "$ROOT"; exit 0; }

PARENT="$(dirname -- "$STATE_DIR")"
[ ! -L "$PARENT" ] || { echo "refusing symlinked state parent" >&2; exit 7; }
[ ! -L "$STATE_DIR" ] || { echo "refusing symlinked state directory" >&2; exit 7; }
[ ! -e "$STATE_DIR" ] || [ -d "$STATE_DIR" ] \
  || { echo "state path is not a directory" >&2; exit 7; }

$READ_ONLY || mkdir -p "$STATE_DIR" || exit 7
printf '%s\n' "$STATE_DIR"
