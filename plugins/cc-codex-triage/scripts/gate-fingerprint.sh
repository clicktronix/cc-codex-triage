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
# `write-tree` records a submodule as a gitlink, so edits inside one would leave
# the fingerprint identical; dirty submodules are detected and folded in
# separately (below) for exactly that reason.
#
# One known cost: each run rehashes the worktree from an empty index with no stat
# cache — sub-second at this repo's scale, but it is the hook's main cost on a
# monorepo, and it leaves a few unreferenced loose objects per content change.
set -u
STATE_DIR=".claude/codex-threads"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$ROOT" ] || exit 0
cd "$ROOT" 2>/dev/null || exit 0

# Dirty submodules, detected against the REAL index and therefore BEFORE the
# throwaway one is swapped in — afterwards everything is staged and nothing
# reads as modified.
#
# `write-tree` records a submodule as a GITLINK, the commit it points at, so
# edits inside one leave the superproject tree identical and no cycle ever
# opens. Worse than a blind spot: the fingerprint is still non-empty, so the
# caller does not fall back to the dirty-tree predicate either.
#
# `git submodule status` is the WRONG probe here — its `+` marks a differing
# COMMIT, not a dirty worktree, and a plain content edit leaves it unchanged
# (verified). `git status --porcelain` on the submodule paths is the signal.
#
# Lazy: clean and uninitialised submodules are fully described by their gitlink,
# so only dirty initialised ones are recursed into. A repository without
# submodules pays one `git submodule status` and nothing more.
#
# Every git call here is status-checked on its own, NOT through a pipeline: a
# pipeline reports the LAST command's status, so `git … | awk` returned awk's 0
# and a forced `git submodule status` failure produced the same confident hash
# before and after a dirty child edit — the fabricated-hash outcome this script
# promises never to produce.
#
# Paths are carried one per line and never word-split: a submodule at
# `vendor lib` was silently dropped by the previous `-- $SUB_PATHS`.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SUB_RAW="$(git submodule status --recursive 2>/dev/null)" || exit 0
DIRTY_SUBS=""
if [ -n "$SUB_RAW" ]; then
  # ` <sha> <path> (<describe>)`, where the leading column is the status flag and
  # the describe suffix is absent for uninitialised entries. Stripping the ends
  # keeps whatever is between them, spaces included — awk's $2 could not.
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _sub="$(printf '%s' "$_line" | sed -e 's/^.//' -e 's/^[0-9a-f][0-9a-f]* //' -e 's/ ([^)]*)$//')"
    [ -n "$_sub" ] || continue
    # `--ignore-submodules=none` overrides submodule.<name>.ignore and
    # diff.ignoreSubmodules: with `dirty` or `all` configured, modified contents
    # produce NO porcelain output, and the script would return a confident
    # unchanged hash for a submodule the user had edited. Those settings exist
    # to keep `git status` quiet, which is precisely why a gate must not honour
    # them. `--no-optional-locks` because this probe runs at every turn end and
    # has no business refreshing the real index.
    _st="$(git --no-optional-locks status --porcelain --ignore-submodules=none -- "$_sub" 2>/dev/null)" || exit 0
    [ -n "$_st" ] || continue
    DIRTY_SUBS="$DIRTY_SUBS$_sub
"
  done <<EOF
$SUB_RAW
EOF
fi

# Scoped (autoplan) mode: keep the dirty submodules that intersect the scope.
# Skipping submodules here entirely left a dirty `docs/plans` submodule
# invisible to the plan gate — the one place where a plan document living in a
# submodule is not exotic at all.
#
# The test is a path-prefix one in both directions (a submodule under a scoped
# directory, or a scoped path inside a submodule), which is what the pathspecs
# this runs with actually are: directory names from CC_CODEX_PLAN_PATHS.
if [ "$#" -gt 0 ] && [ -n "$DIRTY_SUBS" ]; then
  _keep=""
  set -f
  OLD_IFS="$IFS"; IFS='
'
  for _s in $DIRTY_SUBS; do
    IFS="$OLD_IFS"
    for _spec in "$@"; do
      _spec="${_spec%/}"
      case "$_s" in
        "$_spec"|"$_spec"/*) _keep="$_keep$_s
"; break ;;
      esac
      case "$_spec" in
        "$_s"/*) _keep="$_keep$_s
"; break ;;
      esac
    done
    IFS='
'
  done
  IFS="$OLD_IFS"
  set +f
  DIRTY_SUBS="$_keep"
fi

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
  # Status-checked, not piped into `head`: a pipeline reports the LAST command's
  # status, so an invalid pathspec (git exits 128) read as "matches nothing" and
  # the script returned the empty-tree hash — which autoplan would then treat as
  # a stable "no plan docs" forever.
  SPECS=""
  for spec in "$@"; do
    _m="$(git ls-files -c -o --exclude-standard -- "$spec" 2>/dev/null)" || exit 0
    [ -z "$_m" ] || SPECS="$SPECS $spec"
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

TREE="$(git write-tree 2>/dev/null)" || exit 0
[ -n "$TREE" ] || exit 0

# Fold in the fingerprints of DIRTY submodules collected before the index was
# swapped (see above). Their gitlink alone cannot see inside them.
if [ -n "${DIRTY_SUBS:-}" ]; then
  SUB_FP=""
  OLD_IFS="$IFS"; IFS='
'
  for sub in $DIRTY_SUBS; do
    IFS="$OLD_IFS"
    child="$( cd "$sub" 2>/dev/null && GIT_INDEX_FILE= bash "$SELF" 2>/dev/null )" || exit 0
    [ -n "$child" ] || exit 0          # a submodule we cannot hash means an unknown state
    SUB_FP="$SUB_FP$sub $child
"
    IFS='
'
  done
  IFS="$OLD_IFS"
  TREE="$(printf '%s\n%s' "$TREE" "$SUB_FP" | git hash-object --stdin 2>/dev/null)" || exit 0
fi
printf '%s\n' "$TREE"
