#!/usr/bin/env bash
# cc-codex-triage — canonical code fingerprint for the /autoreview + /autoplan gates.
#
# usage: gate-fingerprint.sh [--plan | --plan-paths | pathspec ...]
#
# --plan       hash the PLAN scope (the pathspecs below).
# --plan-paths print those pathspecs and exit — so the dirt predicates and the
#              arming commands ask for the plan scope instead of each restating
#              what it is. The default lived in four files, and a change that
#              missed one produced a gate comparing two different scopes, i.e.
#              one that can never release.
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
# Every git call is status-checked and never read through a pipeline (a pipeline
# reports the LAST command's status): a silenced failure produced a confident but
# fabricated hash, the one outcome this script promises never to produce.
#
# `write-tree` records a submodule as a gitlink, so content edits inside one
# would leave the fingerprint identical — dirty submodules are folded in below.
#
# Cost: each run rehashes the worktree from an empty index with no stat cache.
set -u
STATE_DIR=".claude/codex-threads"

# Plan-doc locations, configurable via CC_CODEX_PLAN_PATHS (space-separated).
PLAN_PATHS="${CC_CODEX_PLAN_PATHS:-docs/plans docs/PLANS}"
if [ "${1:-}" = "--plan-paths" ]; then printf '%s\n' "$PLAN_PATHS"; exit 0; fi
# shellcheck disable=SC2086 — splitting into separate pathspecs is intended
if [ "${1:-}" = "--plan" ]; then set -f; set -- $PLAN_PATHS; set +f; fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$ROOT" ] || exit 0
cd "$ROOT" 2>/dev/null || exit 0

# Dirty submodules, detected against the REAL index and therefore BEFORE the
# throwaway one is swapped in — afterwards everything is staged and nothing
# reads as modified. A gitlink hides content edits AND keeps the fingerprint
# non-empty, so the caller does not fall back to the dirty-tree predicate
# either. Only dirty ones are recursed into; clean and uninitialised submodules
# are fully described by their gitlink.
#
# `diff-files --raw` names them directly, one `:160000 … <TAB>path` line each:
# no enumerate-then-probe pass, no per-path spawn, and the tab keeps a path like
# `vendor lib` intact. It is also 8x cheaper than `git submodule status`, which
# this runs instead of — and this runs at every turn end, per armed gate.
# `--ignore-submodules=none` overrides submodule.<name>.ignore and
# diff.ignoreSubmodules: those exist to keep `git status` quiet, which is
# exactly why a gate must not honour them. `--no-optional-locks` keeps a
# read-only probe from refreshing the real index.
SUB_RAW="$(git --no-optional-locks diff-files --ignore-submodules=none --raw 2>/dev/null)" || exit 0
DIRTY_SUBS="$(printf '%s\n' "$SUB_RAW" | awk -F'\t' '/^:160000/ {print $2}')"

# Scoped (autoplan) mode: keep the dirty submodules that intersect the scope.
# Skipping submodules here entirely left a dirty `docs/plans` submodule
# invisible to the plan gate — the one place where a plan document living in a
# submodule is not exotic at all.
#
# The two path-prefix directions need OPPOSITE treatment:
#
#   submodule UNDER a scoped directory — its gitlink is inside the scoped tree
#     already, so a clean one is fully described and only a dirty one needs
#     folding in whole. Same rule as whole-tree mode.
#
#   scoped path INSIDE a submodule — git cannot descend into a gitlink, so the
#     scoped tree contains NOTHING of it, dirty or clean. Two things follow.
#     (a) The recursion must carry the pathspec down, rewritten relative to the
#         submodule root; folding the submodule in whole made any edit anywhere
#         inside it move the plan fingerprint, so the hook demanded a paid plan
#         round for a change that touched no plan document.
#     (b) It must be folded in on EVERY run, not only when the submodule reads
#         as dirty — otherwise an out-of-scope edit still moves the fingerprint
#         by adding the fold line itself, which is (a) again by another route.
#         So these are found from the pathspecs, not from the dirty list.
#
# Kept entries are `path` (whole) or `path<TAB>relspec relspec...` (scoped).
if [ "$#" -gt 0 ]; then
  set -f
  # (b): ancestor prefixes of every scoped path, asked about in ONE ls-files
  # call. Only prefixes can be gitlinks in THIS repo; anything deeper belongs to
  # the submodule's own index and the recursion finds it there.
  # Newline-separated, like DIRTY_SUBS: a pathspec containing a space must reach
  # git as ONE argument.
  _prefixes=""
  for _spec in "$@"; do
    _p="${_spec%/}"
    while [ "${_p%/*}" != "$_p" ]; do
      _p="${_p%/*}"
      _prefixes="$_prefixes$_p
"
    done
  done
  _keep=""
  OLD_IFS="$IFS"; IFS='
'
  _gitlinks=""
  if [ -n "$_prefixes" ]; then
    # shellcheck disable=SC2086 — splitting on newline into pathspecs is intended
    _ls="$(git --no-optional-locks ls-files -s -- $_prefixes 2>/dev/null)" || exit 0
    _gitlinks="$(printf '%s\n' "$_ls" | awk -F'\t' '/^160000 /{print $2}')"
  fi

  for _s in $DIRTY_SUBS; do
    [ -n "$_s" ] || continue
    IFS="$OLD_IFS"
    for _spec in "$@"; do
      _spec="${_spec%/}"
      case "$_s" in
        "$_spec"|"$_spec"/*) _keep="$_keep$_s
"; break ;;
      esac
    done
    IFS='
'
  done
  for _s in $_gitlinks; do
    [ -n "$_s" ] || continue
    IFS="$OLD_IFS"
    # A submodule kept whole above wins — do not fold it twice.
    case "
$_keep" in *"
$_s
"*) IFS='
'; continue ;;
    esac
    _rel=""
    for _spec in "$@"; do
      _spec="${_spec%/}"
      case "$_spec" in
        "$_s"/*) _rel="$_rel ${_spec#"$_s"/}" ;;
      esac
    done
    [ -z "$_rel" ] || _keep="$_keep$_s	${_rel# }
"
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

# Whole-tree runs SEED the throwaway index from a cached copy, so git's stat
# cache survives between turns and `git add -A` re-hashes only what actually
# changed. From a cold empty index every turn end rehashes the entire worktree
# — 0.2 s here, seconds on a monorepo, twice per Stop with both gates armed,
# against a 30 s hook timeout past which the gates stop evaluating at all.
#
# A corrupt cache is NOT self-repairing: git rejects an invalid index outright,
# so `add -A` fails, the run returns no fingerprint, and the same bad file is
# recopied every turn — a permanent degradation to the dirty-tree predicate,
# which is the "commit makes the gate go quiet" failure this branch removed. So
# a failure on a seeded index discards the cache and retries once cold, and only
# a cold failure is a real one. Concurrent runs each work on their own copy, so
# the worst a race costs is a colder cache. Scoped runs keep the cold index —
# they cover two directories, and a cache keyed on one scope would carry entries
# from another.
CACHE="$STATE_DIR/gate-index"
SEEDED=0
if [ "$#" -eq 0 ] && [ -f "$CACHE" ]; then
  if cp "$CACHE" "$IDX" 2>/dev/null; then SEEDED=1; else rm -f "$IDX"; fi
fi
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
  if ! git add -A -- . >/dev/null 2>&1; then
    # Seeded run failed: assume the cache and retry once from a cold index.
    [ "$SEEDED" = "1" ] || exit 0
    rm -f "$CACHE" 2>/dev/null
    rm -f "$IDX" 2>/dev/null
    SEEDED=0
    git add -A -- . >/dev/null 2>&1 || exit 0
  fi
  # A file that became gitignored is still TRACKED in a seeded index — ignore
  # rules do not evict existing entries — so it would keep contributing to the
  # hash, contradicting the exclusion this script documents. Cold indexes never
  # have the problem.
  if [ "$SEEDED" = "1" ]; then
    _ign="$(git ls-files -c -i --exclude-standard 2>/dev/null)" || exit 0
    if [ -n "$_ign" ]; then
      printf '%s\n' "$_ign" | git update-index --force-remove --stdin >/dev/null 2>&1 || exit 0
    fi
  fi
  # Status-checked like the rest: if this fails for a reason --ignore-unmatch
  # does not cover, the tree would include the state dir and the gate would
  # re-arm on the driver's own writes until the cap.
  git rm -r --cached --ignore-unmatch -q -- "$STATE_DIR" >/dev/null 2>&1 || exit 0
fi

TREE="$(git write-tree 2>/dev/null)" || exit 0
[ -n "$TREE" ] || exit 0

# Refresh the cache with the index we just built, atomically.
if [ "$#" -eq 0 ] && [ -d "$STATE_DIR" ]; then
  cp "$IDX" "$CACHE.$$" 2>/dev/null && mv -f "$CACHE.$$" "$CACHE" 2>/dev/null || rm -f "$CACHE.$$" 2>/dev/null
fi

# Fold in the fingerprints of DIRTY submodules collected before the index was
# swapped (see above). Their gitlink alone cannot see inside them.
if [ -n "${DIRTY_SUBS:-}" ]; then
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  SUB_FP=""
  OLD_IFS="$IFS"; IFS='
'
  for sub in $DIRTY_SUBS; do
    IFS="$OLD_IFS"
    subspecs=""
    case "$sub" in
      *"	"*) subspecs="${sub#*	}"; sub="${sub%%	*}" ;;
    esac
    # A submodule whose worktree directory is GONE (a `:160000 … D` line: the
    # removal is not committed yet) has no content left to hash, and its gitlink
    # deletion is already in TREE. Aborting the whole fingerprint here disabled
    # the cycle model for both gates until the removal was committed — the very
    # "commit makes the gate go quiet" failure this file exists to remove.
    [ -d "$sub" ] || continue
    # `env -u`, not `GIT_INDEX_FILE=`: git falls back to .git/index only when
    # the variable is ABSENT. Set to the empty string it is a literal index
    # path, so the child probed an empty index, saw no gitlinks, and a dirty
    # NESTED submodule was folded in as unchanged.
    # shellcheck disable=SC2086 — splitting $subspecs into pathspecs is intended
    child="$( cd "$sub" 2>/dev/null && set -f && env -u GIT_INDEX_FILE bash "$SELF" $subspecs 2>/dev/null )" || exit 0
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
