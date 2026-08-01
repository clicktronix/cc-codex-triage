#!/usr/bin/env bash
# cc-codex-triage — canonical code fingerprint for the /autoreview + /autoplan gates.
#
# usage: gate-fingerprint.sh [pathspec ...]
#
# Prints a hash of the working-tree CONTENT in scope, or nothing when it cannot
# be computed. Callers treat empty as "unknown" and fail OPEN, never as
# "unchanged". Shared by the Stop hook and both arming commands — a second copy
# that drifted by one pathspec would make every gate look permanently dirty.
#
# Content, not git bookkeeping, because the gates need both directions: a fix
# survives its own commit (so the gate stays engaged through it), and committing
# already-approved bytes changes nothing (so it costs no review round). Feeding
# `git rev-parse HEAD` into the hash got the second one wrong.
#
# `git add -A` honours .gitignore — deliberate, a gate firing on .env or build
# output would be unusable — and covers untracked files by content, which a new
# plan document needs for its whole first life.
#
# Every git call is status-checked: a silenced failure produced a confident but
# fabricated hash, the one outcome this script promises never to produce.
#
# Two known bounds. `write-tree` records a submodule as a gitlink, so uncommitted
# changes INSIDE a submodule do not move the fingerprint (the old porcelain check
# saw them). And each run rehashes the worktree from an empty index with no stat
# cache — sub-second at this repo's scale, but it is the hook's main cost on a
# monorepo, and it leaves a few unreferenced loose objects per content change.
set -u
STATE_DIR=".claude/codex-threads"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$ROOT" ] || exit 0
cd "$ROOT" 2>/dev/null || exit 0

IDX="$(mktemp "${TMPDIR:-/tmp}/cc-gate-idx.XXXXXX")" || exit 0
rm -f "$IDX"                        # git needs to create it; a 0-byte file is not a valid index
trap 'rm -f "$IDX" "$IDX.lock"' EXIT
export GIT_INDEX_FILE="$IDX"        # the repo's real index and worktree are never touched

set -f                              # pathspecs reach git unexpanded
if [ "$#" -gt 0 ]; then
  # `git add` is fatal on a pathspec matching nothing, and "no plan documents
  # yet" is the normal state of a fresh branch. Drop empty ones; if none match,
  # write-tree yields the empty-tree hash — a stable "no plan docs", not a
  # failure that would silently disable the gate.
  SPECS=""
  for spec in "$@"; do
    [ -z "$(git ls-files -c -o --exclude-standard -- "$spec" 2>/dev/null | head -1)" ] || SPECS="$SPECS $spec"
  done
  # shellcheck disable=SC2086 — splitting the collected pathspecs is intended
  [ -z "$SPECS" ] || git add -A -- $SPECS >/dev/null 2>&1 || exit 0
else
  # Not `:(exclude)` on the add: naming an ignored path in a pathspec makes git
  # exit 1, and the state dir is meant to be gitignored. Drop it afterwards
  # instead, which also covers repos that never ignored it.
  git add -A -- . >/dev/null 2>&1 || exit 0
  # Status-checked like the rest: if this fails for a reason --ignore-unmatch
  # does not cover, the tree would include the state dir and the gate would
  # re-arm on the driver's own writes until the cap.
  git rm -r --cached --ignore-unmatch -q -- "$STATE_DIR" >/dev/null 2>&1 || exit 0
fi

git write-tree 2>/dev/null || exit 0
