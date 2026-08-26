#!/usr/bin/env bash
# Resolve persistent state for the current Git worktree.
#
# A Codex session keeps the cwd from its initial `codex exec -C`. Sharing its
# session id with another worktree can therefore review one checkout and label
# another. State lives under the current worktree's absolute Git directory so
# a saved session can only be resumed from the checkout that created it.
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
