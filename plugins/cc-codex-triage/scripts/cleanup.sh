#!/usr/bin/env bash
# cc-codex-triage — /cleanup: find and (optionally) archive stale state.
#
# Usage: cleanup.sh [--apply] [--older-than <days>]
#
# Default is a DRY RUN: it only lists what it found. With --apply it MOVES the
# stale items into an archive subdir (never deletes), so nothing is lost and the
# action is reversible by moving them back.
#
# Detects:
#   - stale armed gates   : autoreview/autoplan armed for a branch != current.
#   - pre-0.5 armed gates : armed files missing log_bytes_at_arming (fail-open).
#   - orphan logs         : <thread>.log with no <thread>.id (never persisted).
#   - stale last-error    : <thread>.last-error.jsonl whose thread has no .id
#                           (orphan diagnostics) or whose .log is newer than
#                           the diag (the thread recovered). A diag NEWER than
#                           the log on a persisted thread is the live last
#                           error — NOT flagged.
#   - dormant threads     : with --older-than <days> (integer >= 1), whole
#                           thread file-sets — id, log, log.1, rounds,
#                           findings.jsonl, scope, approved, last-error.jsonl,
#                           detach-output, active — whose NEWEST member is
#                           older than N days. Listed on dry run, moved
#                           wholesale on --apply.
#   - generic threads     : `review`/`plan` default threads (contamination risk).
#
# Safety rails (in precedence order), applied uniformly by EVERY detection
# class via one shared rail check:
#   1. live lease  — <thread>.active naming a live PID means a dispatch is in
#      flight (a resume waiting inside `codex exec` may write nothing until it
#      returns): the thread is skipped unconditionally. A dead-PID or malformed
#      lease is stale state like any other and joins the archivable set in
#      every class.
#   2. a thread named by an armed gate's `thread=` line is never archived.
#   3. on --apply, targets are grouped into per-thread UNITS and EVERY unit
#      is revalidated immediately before its moves: the rail check re-runs
#      adjacent to each unit — never cached across units (a gate re-armed or
#      a dispatch started while earlier units moved -> skip), and each flat
#      target / dormant set is re-stat'ed (mtime changed since detection ->
#      skip). Dormant membership supersedes flat targets: a file queued both
#      ways moves exactly once, with its whole set.
#   4. generic `review`/`plan` threads are listed but never auto-archived.

set -u

# Shared helpers (field / has_field / _mtime_epoch). Resolve the script's own
# dir BEFORE the cd below so the source path stays valid regardless of caller
# cwd.
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SELF_DIR/lib.sh"

# ── args ──────────────────────────────────────────────────────────────────
APPLY=false
OLDER_DAYS=""
usage() { echo "usage: cleanup.sh [--apply] [--older-than <days>]" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --older-than)
      [ $# -ge 2 ] || { echo "--older-than needs a value (days)" >&2; usage; }
      # Integer >= 1 only: 0 would mean "archive everything", negatives and
      # non-numerics are user error — refuse loudly instead of guessing.
      # Length is capped at 5 digits (100000 days ≈ 274 years) so the
      # days*86400 arithmetic below can never overflow, and the value is
      # normalized base-10 ($((10#...))) so a leading-zero "08" is handled as
      # 8 instead of tripping bash's invalid-octal parsing.
      case "$2" in
        ''|*[!0-9]*) echo "--older-than must be an integer >= 1 (got '$2')" >&2; usage ;;
      esac
      [ "${#2}" -le 5 ] || { echo "--older-than is capped at 5 digits (got '$2')" >&2; usage; }
      OLDER_DAYS=$((10#$2))
      [ "$OLDER_DAYS" -ge 1 ] || { echo "--older-than must be an integer >= 1 (got '$2')" >&2; usage; }
      shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

# Anchor to the RESOLVED repo root (mirrors the driver's rule): a
# CLAUDE_PROJECT_DIR naming a repo SUBDIR resolves UP — state always lives at
# the repo ROOT. HARD-FAIL outside a repo (exit 7, driver parity): this script
# MUTATES state on --apply, and a fail-soft fallback would operate on whatever
# ./.claude/codex-threads happens to sit in the caller's cwd — state the
# driver could never have written there (it refuses to run outside a repo).
if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "cleanup.sh must run inside a git repository (thread state lives at the repo root)" >&2
  exit 7
fi
cd "$ROOT" || exit 7
STATE_DIR=".claude/codex-threads"

[ -d "$STATE_DIR" ] || { echo "No state directory ($STATE_DIR) — nothing to clean."; exit 0; }
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
NOW="$(date +%s)"

# ── helpers ───────────────────────────────────────────────────────────────
# Every known per-thread state file (deduplicated — the extensions are
# distinct). Kept in ONE place so the dormant file-set and the mtime scan can
# never drift apart.
THREAD_EXTS="id log log.1 rounds findings.jsonl scope approved last-error.jsonl detach-output active"

# Existing member paths of a thread's file-set, one per line.  $1=thread
thread_files() {
  local ext
  for ext in $THREAD_EXTS; do
    [ -f "$STATE_DIR/$1.$ext" ] && printf '%s\n' "$STATE_DIR/$1.$ext"
  done
  return 0
}

# Newest mtime (epoch) across a thread's file-set; empty when no member exists.
newest_mtime() {
  local ext m newest=""
  for ext in $THREAD_EXTS; do
    [ -f "$STATE_DIR/$1.$ext" ] || continue
    m="$(_mtime_epoch "$STATE_DIR/$1.$ext")"
    [ -n "$m" ] || continue
    if [ -z "$newest" ] || [ "$m" -gt "$newest" ]; then newest="$m"; fi
  done
  printf '%s' "$newest"
}

# Rail 1: true when <thread>.active holds a strictly positive decimal PID that
# is alive (`kill -0`). Dead-PID / malformed content -> NOT live (stale lease).
# The grammar is the DRIVER's canonical one (^[1-9][0-9]{0,11}$) applied to the
# post-command-substitution content — no whitespace normalization beyond what
# $(cat) itself does (it strips trailing newlines, identically in the driver):
# the driver writes the bare PID with printf '%s' "$$", so "0<pid>", " <pid>",
# or an embedded newline/additional line are spellings it never produces and
# must read as malformed (stale), not IN USE.
lease_live() {
  local f="$STATE_DIR/$1.active" pid
  [ -f "$f" ] || return 1
  pid="$(cat "$f" 2>/dev/null)"
  [[ "$pid" =~ ^[1-9][0-9]{0,11}$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}
lease_pid() { cat "$STATE_DIR/$1.active" 2>/dev/null; }

# Rail 2: true when either armed gate's thread= names this thread.
armed_target() {
  local k
  for k in autoreview autoplan; do
    [ -f "$STATE_DIR/$k.armed" ] || continue
    [ "$(field "$STATE_DIR/$k.armed" thread)" = "$1" ] && return 0
  done
  return 1
}

# Central per-thread rail check — called by EVERY detection class (and re-run
# at apply time), so no class can drift out of the rails again.
# Returns: 0 = archivable; 1 = live lease (IN USE); 2 = armed-gate target
# (SKIP); 3 = generic review/plan name (list-only). Precedence mirrors the
# documented rail order: live lease > armed target > generic name.
rail_check() {
  lease_live "$1" && return 1
  armed_target "$1" && return 2
  case "$1" in review|plan) return 3 ;; esac
  return 0
}

# ── apply-time mutex (driver protocol parity) ─────────────────────────────
# The driver serializes lease acquisition through the mkdir mutex
# <thread>.active.lock and only writes <thread>.active while holding it. A
# rail check alone therefore has a TOCTOU window: a dispatch could acquire
# the lease between the check and this unit's `mv`s. Closing it requires
# taking the SAME mutex around check+moves — while cleanup holds the lock, a
# concurrent dispatch loses the acquisition (exit 10, "retry shortly") instead
# of racing the archive. Takeover mirrors the driver exactly: a lock whose
# recorded owner is ALIVE is never stolen; a dead/invalid owner is reclaimed
# at once; an ownerless lock older than 60s (acquirer crashed between mkdir
# and the token write) is reclaimed too.
# unit_lock returns: 0 = held (owner token published); 1 = busy (a live
# acquirer/dispatch holds it — treat the unit as IN USE).
unit_lock() { # $1=thread
  local lock="$STATE_DIR/$1.active.lock" owner mt
  if ! mkdir "$lock" 2>/dev/null; then
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[1-9][0-9]{0,11}$ ]] && kill -0 "$owner" 2>/dev/null; then
      return 1
    fi
    if [ -e "$lock/owner" ]; then
      : # dead/garbage owner: reclaim now
    else
      mt="$(stat -f '%m' "$lock" 2>/dev/null || stat -c '%Y' "$lock" 2>/dev/null || true)"
      case "$mt" in
        *[!0-9]*|'') return 1 ;;
        *) [ $((NOW - mt)) -gt 60 ] || return 1 ;;
      esac
    fi
    rm -f "$lock/owner" 2>/dev/null || true
    rmdir "$lock" 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || return 1
  fi
  # Publish ownership with noclobber (driver rule): an existing token means
  # the dir was reclaimed out from under us — lose without touching it.
  if ! (set -C; printf '%s' "$$" > "$lock/owner") 2>/dev/null; then
    return 1
  fi
  return 0
}
unit_unlock() { # $1=thread — ownership-checked release, driver parity.
  local lock="$STATE_DIR/$1.active.lock"
  if [ "$(cat "$lock/owner" 2>/dev/null)" = "$$" ]; then
    rm -f "$lock/owner"
    rmdir "$lock" 2>/dev/null || true
  fi
}
# Standard skip note for a non-zero rail_check result. $1=thread $2=rail code
rail_note() {
  case "$2" in
    1) echo "  IN USE  $1  (dispatch in flight, pid=$(lease_pid "$1")) — skipped" ;;
    2) echo "  SKIP    $1  (targeted by an armed gate) — not archived" ;;
    3) echo "  GENERIC $1  (generic thread — listed only, never auto-archived)" ;;
  esac
}
# A dead/malformed lease is stale state in EVERY class: whenever a thread has
# passed the rails (so the lease is NOT live) and files of it are being
# archived, its .active joins them. $1=thread
add_dead_lease() {
  [ -f "$STATE_DIR/$1.active" ] && add_archive "$STATE_DIR/$1.active"
  return 0
}

# Thread name owning a state-file path; empty for gate files and unknown
# names. Shared by the dormant grouping scan and apply-time revalidation.
thread_of() {
  local b n=""
  b="$(basename "$1")"
  case "$b" in
    autoreview.armed|autoplan.armed) ;;
    *.last-error.jsonl) n="${b%.last-error.jsonl}" ;;
    *.findings.jsonl)   n="${b%.findings.jsonl}" ;;
    *.detach-output)    n="${b%.detach-output}" ;;
    *.log.1)            n="${b%.log.1}" ;;
    *.log)              n="${b%.log}" ;;
    *.id)               n="${b%.id}" ;;
    *.rounds)           n="${b%.rounds}" ;;
    *.scope)            n="${b%.scope}" ;;
    *.approved)         n="${b%.approved}" ;;
    *.active)           n="${b%.active}" ;;
  esac
  printf '%s' "$n"
}

# Collect targets to archive. add_archive dedups — a stale diag can be flagged
# both by its own class and as part of an orphan/dormant set; it must be
# queued (and counted) exactly once. The detection-time mtime is recorded per
# target so --apply can re-stat every one of them before moving (rail 3).
declare -a ARCHIVE=()
declare -a ARCHIVE_MTIMES=()
declare -a DORMANT_NAMES=()
declare -a DORMANT_MTIMES=()
ARCHIVED_SET=" "
in_archive()  { case "$ARCHIVED_SET" in *" $1 "*) return 0 ;; esac; return 1; }
add_archive() {
  in_archive "$1" || {
    ARCHIVE+=("$1")
    ARCHIVE_MTIMES+=("$(_mtime_epoch "$1")")
    ARCHIVED_SET="$ARCHIVED_SET$1 "
  }
}
DORMANT_FILE_COUNT=0
issues=0

echo "cc-codex-triage cleanup ($([ "$APPLY" = true ] && echo APPLY || echo 'dry run'))  branch=${BRANCH:-?}"
echo

echo "Armed gates:"
shown=0
for kind in autoreview autoplan; do
  f="$STATE_DIR/$kind.armed"
  [ -f "$f" ] || continue
  shown=1
  ab="$(field "$f" branch)"
  stale=false
  if [ -n "$BRANCH" ] && [ -n "$ab" ] && [ "$ab" != "$BRANCH" ]; then
    echo "  STALE  /$kind armed for '$ab' (you are on '$BRANCH')"; stale=true; issues=$((issues+1))
  fi
  if ! has_field "$f" log_bytes_at_arming; then
    echo "  PRE-0.5 /$kind armed file missing log_bytes_at_arming (hook fails open)"; stale=true; issues=$((issues+1))
  fi
  $stale && add_archive "$f"
done
[ "$shown" = 0 ] && echo "  (no armed gates)"

echo
echo "Orphan logs (a .log with no matching .id — never persisted):"
orphans=0
for lg in "$STATE_DIR"/*.log; do
  [ -f "$lg" ] || continue
  n="$(basename "$lg" .log)"
  if [ ! -f "$STATE_DIR/$n.id" ]; then
    # Rails (all of them): an initial dispatch on a never-persisted thread may
    # be in flight, an armed gate may target it, or it may be a generic name.
    rail_check "$n"; rc=$?
    if [ "$rc" -ne 0 ]; then rail_note "$n" "$rc"; continue; fi
    echo "  ORPHAN  $n  (size $(wc -c < "$lg" 2>/dev/null | tr -d ' ') bytes)"
    orphans=$((orphans+1)); issues=$((issues+1))
    add_archive "$lg"
    # A dead-PID/malformed lease is stale state — .active joins the set.
    for ext in log.1 rounds last-error.jsonl findings.jsonl scope approved detach-output active; do
      [ -f "$STATE_DIR/$n.$ext" ] && add_archive "$STATE_DIR/$n.$ext"
    done
  fi
done
# Sidecar-only orphans: findings/scope/approved with NO .id and NO .log — e.g. a
# failed initial dispatch the .log scan above can't see. Print once per thread.
seen=""
skipped=""
for sc in "$STATE_DIR"/*.findings.jsonl "$STATE_DIR"/*.scope "$STATE_DIR"/*.approved; do
  [ -f "$sc" ] || continue
  b="$(basename "$sc")"; n="${b%.findings.jsonl}"; n="${n%.scope}"; n="${n%.approved}"
  { [ -f "$STATE_DIR/$n.id" ] || [ -f "$STATE_DIR/$n.log" ]; } && continue
  # Rails (all of them): /review pins .scope BEFORE the first dispatch — a
  # live lease means that first dispatch is running right now, not that the
  # sidecar is orphaned. Armed-target and generic names are shielded too.
  rail_check "$n"; rc=$?
  if [ "$rc" -ne 0 ]; then
    case " $skipped " in *" $n "*) ;; *) rail_note "$n" "$rc"; skipped="$skipped $n" ;; esac
    continue
  fi
  case " $seen " in *" $n "*) ;; *) echo "  ORPHAN  $n  (sidecar, no .log/.id)"; orphans=$((orphans+1)); issues=$((issues+1)); seen="$seen $n" ;; esac
  add_archive "$sc"
  add_dead_lease "$n"
done
[ "$orphans" = 0 ] && echo "  (none)"

echo
echo "Stale last-error diags (orphaned, or outlived by a recovered thread):"
stale_diags=0
for dg in "$STATE_DIR"/*.last-error.jsonl; do
  [ -f "$dg" ] || continue
  b="$(basename "$dg")"; n="${b%.last-error.jsonl}"
  reason=""
  if [ ! -f "$STATE_DIR/$n.id" ]; then
    reason="no .id — orphan diagnostics"
  elif [ -f "$STATE_DIR/$n.log" ]; then
    lm="$(_mtime_epoch "$STATE_DIR/$n.log")"; dm="$(_mtime_epoch "$dg")"
    if [ -n "$lm" ] && [ -n "$dm" ] && [ "$lm" -gt "$dm" ]; then
      reason=".log newer than the diag — thread recovered"
    fi
  fi
  # A diag newer than the log on a persisted thread is the thread's LIVE last
  # error — leave it alone.
  [ -n "$reason" ] || continue
  rail_check "$n"; rc=$?
  if [ "$rc" -ne 0 ]; then rail_note "$n" "$rc"; continue; fi
  echo "  STALE-DIAG  $n  ($reason)"
  stale_diags=$((stale_diags+1)); issues=$((issues+1))
  add_archive "$dg"
  add_dead_lease "$n"
done
[ "$stale_diags" = 0 ] && echo "  (none)"

echo
echo "Generic threads (contamination risk — one name reused across tasks):"
generic=0
for n in review plan; do
  [ -f "$STATE_DIR/$n.id" ] && { echo "  GENERIC $n  (prefer per-task threads: review-<branch> / plan-<topic>)"; generic=$((generic+1)); }
done
[ "$generic" = 0 ] && echo "  (none)"
# Generic threads are NOT auto-archived — they may be active. Listed only.

if [ -n "$OLDER_DAYS" ]; then
  echo
  echo "Dormant threads (newest state file older than $OLDER_DAYS day(s)):"
  CUTOFF=$((NOW - OLDER_DAYS * 86400))
  dormant=0
  # Group files by thread name across every known extension.
  names=""
  for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    n="$(thread_of "$f")"
    [ -n "$n" ] || continue
    case " $names " in *" $n "*) ;; *) names="$names $n" ;; esac
  done
  for n in $names; do
    newest="$(newest_mtime "$n")"
    [ -n "$newest" ] || continue
    [ "$newest" -lt "$CUTOFF" ] || continue
    # Rails: a live lease wins over any mtime evidence — a resume waiting
    # inside `codex exec` may not have written a byte yet — then armed
    # targets; generic names fall through to the list-only note below.
    rail_check "$n"; rc=$?
    if [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ]; then rail_note "$n" "$rc"; continue; fi
    age_days=$(( (NOW - newest) / 86400 ))
    members="$(thread_files "$n" | sed "s|^$STATE_DIR/||" | tr '\n' ' ')"
    if [ "$rc" -eq 3 ]; then
      echo "  DORMANT $n  (${age_days}d idle; generic thread — listed only, never auto-archived)"
      dormant=$((dormant+1)); issues=$((issues+1))
      continue
    fi
    echo "  DORMANT $n  (${age_days}d idle: ${members})"
    dormant=$((dormant+1)); issues=$((issues+1))
    DORMANT_NAMES+=("$n"); DORMANT_MTIMES+=("$newest")
    cnt=0
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      in_archive "$p" || cnt=$((cnt+1))
    done <<EOF
$(thread_files "$n")
EOF
    DORMANT_FILE_COUNT=$((DORMANT_FILE_COUNT + cnt))
  done
  [ "$dormant" = 0 ] && echo "  (none)"
fi

echo
PLANNED=$(( ${#ARCHIVE[@]} + DORMANT_FILE_COUNT ))
if [ "$PLANNED" -eq 0 ]; then
  echo "Nothing to archive. ${issues} note(s) above."
  exit 0
fi

if [ "$APPLY" = true ]; then
  # Unique dir (mktemp) so a second run in the same second can't reuse it; no
  # `mv -f` and an explicit name-clash skip so the "never deletes/overwrites"
  # contract holds; count only successful moves.
  dest="$(mktemp -d "$STATE_DIR/.archive-$(date +%Y%m%d-%H%M%S)-XXXXXX")" || { echo "ERROR: could not create archive dir"; exit 1; }
  moved=0
  move_one() {
    [ -e "$1" ] || return 0
    b="$(basename "$1")"
    if [ -e "$dest/$b" ]; then echo "  SKIP (name clash, not overwritten): $b"; return 0; fi
    if mv "$1" "$dest/"; then moved=$((moved+1)); echo "  archived: $b"; else echo "  FAILED to move: $b"; fi
  }
  # Apply-time revalidation (rail 3), organized as per-thread UNITS: every
  # target belonging to a thread — flat or dormant — is applied as ONE unit,
  # with the rail check and the freshness re-stat run immediately adjacent to
  # its moves. NO cross-unit caching: a lease or armed gate appearing while
  # earlier units were moving is seen by every later unit. Dormant membership
  # SUPERSEDES flat targets: a file queued both ways moves exactly once, WITH
  # its set — moving it early as a flat target would change the set's newest
  # mtime and self-trigger the changed-since-detection skip, leaving the
  # promised whole-set archive half-done.
  apply_rail_note() { # $1=thread $2=rail code
    case "$2" in
      1) echo "  SKIP (in use since detection): thread $1" ;;
      2) echo "  SKIP (armed since detection): thread $1" ;;
      *) echo "  SKIP (generic thread): $1" ;;
    esac
  }
  is_dormant() { # $1=thread
    local j=0
    while [ "$j" -lt "${#DORMANT_NAMES[@]}" ]; do
      [ "${DORMANT_NAMES[$j]}" = "$1" ] && return 0
      j=$((j+1))
    done
    return 1
  }
  DONE_THREADS=" "
  i=0
  while [ "$i" -lt "${#ARCHIVE[@]}" ]; do
    p="${ARCHIVE[$i]}"; det="${ARCHIVE_MTIMES[$i]}"; i=$((i+1))
    n="$(thread_of "$p")"
    if [ -z "$n" ]; then
      # Not thread-owned (armed gate files): a unit of one — re-stat
      # immediately before the move.
      cur="$(_mtime_epoch "$p")"
      if [ "$cur" != "$det" ]; then
        echo "  SKIP (changed since detection): ${p#"$STATE_DIR"/}"
        continue
      fi
      move_one "$p"
      continue
    fi
    is_dormant "$n" && continue      # superseded: moves with its whole set below
    case "$DONE_THREADS" in *" $n "*) continue ;; esac
    DONE_THREADS="$DONE_THREADS$n "
    # One unit, under the thread's acquisition mutex: lock → re-check the
    # rails INSIDE the lock → move → unlock. Without the lock, a dispatch
    # could acquire the lease between the rail check and the moves.
    if ! unit_lock "$n"; then apply_rail_note "$n" 1; continue; fi
    # Test seam: lets the regression suite inject state (e.g. a live lease)
    # between lock acquisition and the under-lock re-check, proving the
    # re-check runs after the last possible legitimate write.
    [ -n "${CC_CLEANUP_TEST_POST_LOCK_HOOK:-}" ] && . "$CC_CLEANUP_TEST_POST_LOCK_HOOK"
    rail_check "$n"; rc=$?
    if [ "$rc" -ne 0 ]; then unit_unlock "$n"; apply_rail_note "$n" "$rc"; continue; fi
    j=0
    while [ "$j" -lt "${#ARCHIVE[@]}" ]; do
      q="${ARCHIVE[$j]}"; qdet="${ARCHIVE_MTIMES[$j]}"; j=$((j+1))
      [ "$(thread_of "$q")" = "$n" ] || continue
      cur="$(_mtime_epoch "$q")"
      if [ "$cur" != "$qdet" ]; then
        echo "  SKIP (changed since detection): ${q#"$STATE_DIR"/}"
        continue
      fi
      move_one "$q"
    done
    unit_unlock "$n"
  done
  # Dormant sets move wholesale — one unit per thread: the rail check and the
  # whole-set freshness re-stat run immediately before its members move
  # (including any member that was also queued as a flat target above).
  i=0
  while [ "$i" -lt "${#DORMANT_NAMES[@]}" ]; do
    n="${DORMANT_NAMES[$i]}"; det="${DORMANT_MTIMES[$i]}"; i=$((i+1))
    # Same lock discipline as the flat units above: rails re-checked and the
    # whole set moved under the thread's acquisition mutex.
    if ! unit_lock "$n"; then apply_rail_note "$n" 1; continue; fi
    [ -n "${CC_CLEANUP_TEST_POST_LOCK_HOOK:-}" ] && . "$CC_CLEANUP_TEST_POST_LOCK_HOOK"
    rail_check "$n"; rc=$?
    if [ "$rc" -ne 0 ]; then unit_unlock "$n"; apply_rail_note "$n" "$rc"; continue; fi
    cur="$(newest_mtime "$n")"
    if [ "$cur" != "$det" ]; then
      echo "  SKIP (changed since detection): thread $n"
      unit_unlock "$n"
      continue
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      move_one "$p"
    done <<EOF
$(thread_files "$n")
EOF
    unit_unlock "$n"
  done
  echo "Archived $moved/$PLANNED item(s) to $dest (reversible — move them back to restore)."
else
  echo "Would archive $PLANNED item(s). Re-run with --apply to move them to an archive subdir (non-destructive)."
fi
