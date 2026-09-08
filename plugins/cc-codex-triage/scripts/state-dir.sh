#!/usr/bin/env bash
# Resolve persistent state for the current Git worktree.
#
# Keep each task's conversation scoped to its worktree by policy. The driver
# explicitly passes this checkout on resume too. State is not shared implicitly
# with another checkout; retain needed history before removing a worktree.
#
# usage: state-dir.sh [--read-only]
set -u
umask 077

READ_ONLY=false
case "${1:-}" in
  "") ;;
  --read-only) READ_ONLY=true ;;
  *) echo "usage: state-dir.sh [--read-only]" >&2; exit 1 ;;
esac

if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
    || [ -z "$ROOT" ]; then
  echo "not inside a git repository" >&2
  exit 7
fi

GIT_DIR="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null)" \
  || { echo "cannot resolve the worktree Git directory" >&2; exit 7; }
STATE_DIR="$GIT_DIR/cc-codex-triage/threads"

PARENT="$(dirname -- "$STATE_DIR")"
[ ! -L "$PARENT" ] || { echo "refusing symlinked state parent" >&2; exit 7; }
[ ! -L "$STATE_DIR" ] || { echo "refusing symlinked state directory" >&2; exit 7; }
[ ! -e "$STATE_DIR" ] || [ -d "$STATE_DIR" ] \
  || { echo "state path is not a directory" >&2; exit 7; }

$READ_ONLY || mkdir -p "$STATE_DIR" || exit 7
printf '%s\n' "$STATE_DIR"
