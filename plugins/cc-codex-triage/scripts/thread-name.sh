#!/usr/bin/env bash
# Print a branch-scoped default thread name.
# usage: thread-name.sh review|plan|research
set -u

case "${1:-}" in review|plan|research) PREFIX="$1" ;; *) echo "usage: thread-name.sh review|plan|research" >&2; exit 1 ;; esac
ROOT="$(bash "$(cd "$(dirname "$0")" && pwd)/state-dir.sh" --root)" || exit $?
if git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  if ref="$(git -C "$ROOT" symbolic-ref -q HEAD)"; then
    branch="${ref#refs/heads/}"
  else
    ref="$(git -C "$ROOT" rev-parse --verify HEAD)" || exit 7
    branch=detached
  fi
  slug="$(printf '%s' "$branch" | LC_ALL=C tr -c 'a-zA-Z0-9_.-' '-')"
  digest="$(printf '%s' "$ref" | git -C "$ROOT" hash-object --stdin)" || exit 7
  name="$PREFIX-${slug:0:80}-${digest:0:12}"
  if [ "$PREFIX" = review ]; then
    state="$(bash "$(dirname "$0")/state-dir.sh" --read-only)" || exit $?
    legacy="$PREFIX-$slug"
    # Legacy names contain no ref. Reuse a required contract only when its
    # saved candidate belongs to this history and no other ref shares the slug.
    if [ ! -f "$state/$name.review-loop" ] && { [ -f "$state/$legacy.review-loop" ] || [ -f "$state/$legacy.review-state" ] || [ -f "$state/$legacy.candidate" ]; }; then
      anchor="$(sed -n 's/^head=//p' "$state/$legacy.candidate" 2>/dev/null | head -1)"
      [ -n "$anchor" ] || anchor="$(sed -n 's/^head=//p' "$state/$legacy.review-state" 2>/dev/null | head -1)"
      matches="$(git -C "$ROOT" for-each-ref --format='%(refname:lstrip=2)' refs/heads | LC_ALL=C sed 's/[^a-zA-Z0-9_.-]/-/g' | grep -Fxc -- "$slug")"
      if [ "$branch" != detached ] && [ "$matches" = 1 ] && [ -n "$anchor" ] && git -C "$ROOT" merge-base --is-ancestor "$anchor" HEAD 2>/dev/null; then
        name="$legacy"
      else
        echo "Choose --thread $legacy to resume the saved review, or --thread $name for a separate review." >&2
        exit 8
      fi
    fi
  fi
  printf '%s\n' "$name"
else
  branch="$(basename "$ROOT")"
  printf '%s-%s\n' "$PREFIX" "$(printf '%s' "$branch" | LC_ALL=C tr -c 'a-zA-Z0-9_.-' '-')"
fi
