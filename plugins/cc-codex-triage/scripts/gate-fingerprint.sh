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

# Content of every untracked, non-ignored file in scope. `--stdin-paths` takes
# newline-separated paths; a path containing a literal newline makes git error
# out mid-stream, which changes the hash and re-arms the gate — failing toward
# a review, never toward a silent release.
untracked_content() {
  git ls-files --others --exclude-standard -- "$@" 2>/dev/null \
    | grep -v "^$STATE_DIR/" \
    | git hash-object --stdin-paths 2>/dev/null
}

if [ "$#" -gt 0 ]; then
  # Pathspec-scoped (autoplan). Globbing is off so the patterns reach git
  # unexpanded — git does its own pathspec matching.
  set -f
  { git rev-parse HEAD 2>/dev/null
    git status --porcelain -uall -- "$@" 2>/dev/null
    git diff HEAD -- "$@" 2>/dev/null
    untracked_content "$@"
  } | git hash-object --stdin 2>/dev/null
else
  { git rev-parse HEAD 2>/dev/null
    git status --porcelain -uall 2>/dev/null | grep -vF "$STATE_DIR/"
    git diff HEAD -- . ":(exclude)$STATE_DIR/" 2>/dev/null
    untracked_content
  } | git hash-object --stdin 2>/dev/null
fi
