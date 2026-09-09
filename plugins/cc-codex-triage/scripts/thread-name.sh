#!/usr/bin/env bash
# Print a branch-scoped default thread name.
# usage: thread-name.sh review|plan|research
set -u

case "${1:-}" in review|plan|research) PREFIX="$1" ;; *) echo "usage: thread-name.sh review|plan|research" >&2; exit 1 ;; esac
ROOT="$(bash "$(cd "$(dirname "$0")" && pwd)/state-dir.sh" --root)" || exit $?
if git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  BRANCH="$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || printf detached)"
else
  BRANCH="$(basename "$ROOT")"
fi
SLUG="$(printf '%s' "$BRANCH" | tr -c 'a-zA-Z0-9_.-' '-')"
printf '%s-%s\n' "$PREFIX" "$SLUG"
