#!/usr/bin/env bash
# Print a branch-scoped default thread name.
# usage: thread-name.sh review|plan
set -u

case "${1:-}" in review|plan) PREFIX="$1" ;; *) echo "usage: thread-name.sh review|plan" >&2; exit 1 ;; esac
ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "not inside a git repository" >&2; exit 7; }
BRANCH="$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || printf detached)"
SLUG="$(printf '%s' "$BRANCH" | tr -c 'a-zA-Z0-9_.-' '-')"
printf '%s-%s\n' "$PREFIX" "$SLUG"
