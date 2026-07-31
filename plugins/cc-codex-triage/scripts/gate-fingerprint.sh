#!/usr/bin/env bash
# cc-codex-triage — canonical code fingerprint for the /autoreview + /autoplan gates.
#
# usage: gate-fingerprint.sh [pathspec ...]
#
# Prints a stable hash of the WORKING TREE CONTENT in scope, or nothing at all
# when it cannot be computed. Callers treat empty output as "unknown" and fail
# OPEN — never as "unchanged".
#
# One script, three callers — the Stop hook and both arming commands. The hook
# compares a fingerprint the commands wrote, so a second implementation that
# drifted by one pathspec would make every gate look permanently dirty.
#
# CONTENT, not git bookkeeping. It stages the worktree into a throwaway index
# and hashes the resulting tree, so the fingerprint answers exactly one
# question: "are these the same bytes?" That is what the gates need in both
# directions, and hashing HEAD alongside a diff got one of them wrong:
#
#   - a fix, committed or not, changes the content, so the gate stays engaged
#     through the commit. (A bare `git status --porcelain` check goes quiet the
#     moment the fixes are committed — exactly when the follow-up round is
#     still owed.)
#   - COMMITTING ALREADY-APPROVED CONTENT changes nothing, so it costs no
#     review round. Feeding `git rev-parse HEAD` into the hash made every
#     approve → commit → continue cycle burn a gate round on code Codex had
#     just approved, which on a branch with several commits is how a cap gets
#     consumed. Reproduced before this rewrite.
#
# `git add -A` honours .gitignore, so ignored files stay out — deliberate: a
# gate that fired on .env or build output would be unusable. It also covers
# untracked files by content, which matters because a plan document or a new
# module is untracked for its whole first life and neither its porcelain line
# nor `git diff HEAD` moves while it is edited.
#
# Every git invocation is status-checked. The previous version silenced them
# all and hashed whatever came out, so an unreadable index or a chmod 000 file
# produced a confident but fabricated hash instead of the documented nothing —
# the one outcome this script promises never to produce.
#
# The throwaway index is set via GIT_INDEX_FILE, so the repository's real index
# and worktree are never touched.
set -u
STATE_DIR=".claude/codex-threads"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$ROOT" ] || exit 0            # not a repo → no fingerprint, caller fails open
cd "$ROOT" 2>/dev/null || exit 0

IDX="$(mktemp "${TMPDIR:-/tmp}/cc-gate-idx.XXXXXX")" || exit 0
# git wants to create the index itself; a 0-byte file is not a valid one.
rm -f "$IDX"
trap 'rm -f "$IDX" "$IDX.lock"' EXIT
export GIT_INDEX_FILE="$IDX"

# Globbing off so pathspecs reach git unexpanded — git does its own matching.
set -f
if [ "$#" -gt 0 ]; then
  # Pathspec-scoped (autoplan). `git add` is FATAL on a pathspec that matches
  # nothing — and "no plan documents yet" is the normal state of a fresh
  # branch, not an error — so drop the empty ones first. If none match, the
  # index stays empty and write-tree yields git's empty-tree hash: a stable,
  # meaningful "there are no plan docs", not a failure.
  SPECS=""
  for spec in "$@"; do
    if [ -n "$(git ls-files -c -o --exclude-standard -- "$spec" 2>/dev/null | head -1)" ]; then
      SPECS="$SPECS $spec"
    fi
  done
  # shellcheck disable=SC2086 — word-splitting the collected pathspecs is intended
  [ -z "$SPECS" ] || git add -A -- $SPECS >/dev/null 2>&1 || exit 0
else
  # NOT `:(exclude)` on the add: naming an ignored path in a pathspec makes git
  # exit 1 with "The following paths are ignored by one of your .gitignore
  # files", which is the normal case here — the state dir is meant to be
  # gitignored. Add everything, then drop the state dir from the throwaway
  # index, which also covers repos that never gitignored it.
  git add -A -- . >/dev/null 2>&1 || exit 0
  git rm -r --cached --ignore-unmatch -q -- "$STATE_DIR" >/dev/null 2>&1 || true
fi

git write-tree 2>/dev/null || exit 0
