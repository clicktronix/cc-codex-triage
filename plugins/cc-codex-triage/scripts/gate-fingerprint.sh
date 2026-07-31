#!/usr/bin/env bash
# cc-codex-triage — canonical code fingerprint for the /autoreview + /autoplan gates.
#
# usage: gate-fingerprint.sh [pathspec ...]
#
# Prints a stable hash identifying "the work the gate is watching", or nothing
# at all when it cannot be computed (outside a repo, git failure). Callers treat
# empty output as "unknown" and fail OPEN — never as "unchanged".
#
# One script, three callers — the Stop hook and both arming commands. The hook
# compares a fingerprint the commands wrote, so a second implementation that
# drifted by one pathspec would make every gate look permanently dirty.
#
# What goes into it:
#   - the committed HEAD, so that COMMITTING work is a change rather than a
#     disappearance. A bare `git status --porcelain` check goes quiet the moment
#     the fixes are committed, which is exactly when the follow-up review round
#     is still owed;
#   - the porcelain status, which carries adds, deletes, renames and the PATHS
#     of untracked files;
#   - the tracked-content diff, so editing an already-modified file counts;
#   - the CONTENT of untracked files. Not an afterthought: a new plan document
#     or a new module starts life untracked and is then edited many times, and
#     neither its porcelain line nor `git diff HEAD` moves while that happens.
#     Without this half, an autoplan gate released once and never fired again
#     no matter how much the plan was rewritten.
#
# Excluded everywhere: the plugin's own state dir. The driver writes there
# during every dispatch, and counting that as reviewable work would make the
# gate re-arm on itself until the cap.
#
# Cost: the untracked half reads files that `git status -uall` has already
# walked, in one `git hash-object --stdin-paths` process. A repository with a
# large un-ignored build directory makes this slower — the fix is to gitignore
# it, which `git status -uall` wants anyway.
#
# Hashing is `git hash-object`, not shasum/sha1sum/cksum: git is already a hard
# prerequisite (there is no fingerprint without a repo), so this adds no
# dependency and gives identical output on macOS and Linux.
set -u
STATE_DIR=".claude/codex-threads"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || exit 0            # not a repo → no fingerprint, caller fails open
cd "$ROOT" 2>/dev/null || exit 0

# Content of every untracked, non-ignored file in scope.
#
# `git hash-object --stdin-paths` die()s on the FIRST path it cannot read — a
# dangling symlink, a chmod 000 file, or one removed between `ls-files` and the
# hash — and stops there. The remaining files are never hashed. Left unchecked
# that is the worst possible failure for this gate: the hash changes once and
# then reports "unchanged" forever, so edits to everything after the bad path
# become invisible. Reproduced with a dangling symlink sorting before a file
# that was then edited: the fingerprint did not move.
#
# So the exit status is checked, and a failure produces NO output at all — the
# caller sees an unknown fingerprint and fails open, which is loud in effect
# (the gate stops firing) rather than silently wrong.
#
# Both halves filter the state dir with the SAME `grep -vF` form. They used to
# differ (anchored BRE here, unanchored fixed there) for no reason, and the
# unanchored fixed match is the safer of the two: git C-quotes unusual paths, so
# an anchored pattern misses `?? ".claude/codex-threads/a b"` and lets the gate
# re-arm on the driver's own writes.
untracked_content() {
  local out
  out="$(git ls-files --others --exclude-standard -- "$@" 2>/dev/null \
         | grep -vF "$STATE_DIR/" \
         | git hash-object --stdin-paths 2>/dev/null)" || return 1
  printf '%s' "$out"
}

# `set -e` is not in force, so the untracked half is computed FIRST and its
# failure aborts the whole fingerprint. Inside a pipeline its exit status would
# be discarded and the caller would receive a confidently wrong hash.
UNTRACKED="$(untracked_content "$@")" || exit 0

{ git rev-parse HEAD 2>/dev/null
  if [ "$#" -gt 0 ]; then
    git status --porcelain -uall -- "$@" 2>/dev/null
    git diff HEAD -- "$@" 2>/dev/null
  else
    git status --porcelain -uall 2>/dev/null | grep -vF "$STATE_DIR/"
    git diff HEAD -- . ":(exclude)$STATE_DIR/" 2>/dev/null
  fi
  printf '%s' "$UNTRACKED"
} | git hash-object --stdin 2>/dev/null
