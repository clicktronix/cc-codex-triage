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
# Safety rails (in precedence order):
#   1. live lease  — <thread>.active naming a live PID means a dispatch is in
#      flight (a resume waiting inside `codex exec` may write nothing until it
#      returns): the thread is skipped unconditionally. A dead-PID or malformed
#      lease is stale state like any other and joins the archivable set.
#   2. a thread named by an armed gate's `thread=` line is never archived.
#   3. on --apply, each dormant set's newest mtime is re-checked immediately
#      before the move — changed since detection -> the thread is skipped.
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
      case "$2" in
        ''|*[!0-9]*) echo "--older-than must be an integer >= 1 (got '$2')" >&2; usage ;;
      esac
      [ "$2" -ge 1 ] || { echo "--older-than must be an integer >= 1 (got '$2')" >&2; usage; }
      OLDER_DAYS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" 2>/dev/null || true
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
lease_live() {
  local f="$STATE_DIR/$1.active" pid
  [ -f "$f" ] || return 1
  pid="$(tr -d '[:space:]' < "$f" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] || return 1
  kill -0 "$pid" 2>/dev/null
}
lease_pid() { tr -d '[:space:]' < "$STATE_DIR/$1.active" 2>/dev/null; }

# Rail 2: true when either armed gate's thread= names this thread.
armed_target() {
  local k
  for k in autoreview autoplan; do
    [ -f "$STATE_DIR/$k.armed" ] || continue
    [ "$(field "$STATE_DIR/$k.armed" thread)" = "$1" ] && return 0
  done
  return 1
}

# Collect targets to archive. add_archive dedups — a stale diag can be flagged
# both by its own class and as part of an orphan/dormant set; it must be
# queued (and counted) exactly once.
declare -a ARCHIVE=()
declare -a DORMANT_NAMES=()
declare -a DORMANT_MTIMES=()
ARCHIVED_SET=" "
in_archive()  { case "$ARCHIVED_SET" in *" $1 "*) return 0 ;; esac; return 1; }
add_archive() { in_archive "$1" || { ARCHIVE+=("$1"); ARCHIVED_SET="$ARCHIVED_SET$1 "; }; }
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
    if lease_live "$n"; then
      # Rail 1: an initial dispatch on a never-persisted thread is in flight —
      # archiving its log/sidecars under it would split state.
      echo "  IN USE  $n  (dispatch in flight, pid=$(lease_pid "$n")) — skipped"
      continue
    fi
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
for sc in "$STATE_DIR"/*.findings.jsonl "$STATE_DIR"/*.scope "$STATE_DIR"/*.approved; do
  [ -f "$sc" ] || continue
  b="$(basename "$sc")"; n="${b%.findings.jsonl}"; n="${n%.scope}"; n="${n%.approved}"
  { [ -f "$STATE_DIR/$n.id" ] || [ -f "$STATE_DIR/$n.log" ]; } && continue
  # Rail 1: /review pins .scope BEFORE the first dispatch — a live lease means
  # that first dispatch is running right now, not that the sidecar is orphaned.
  lease_live "$n" && continue
  case " $seen " in *" $n "*) ;; *) echo "  ORPHAN  $n  (sidecar, no .log/.id)"; orphans=$((orphans+1)); issues=$((issues+1)); seen="$seen $n" ;; esac
  add_archive "$sc"
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
  if lease_live "$n"; then
    echo "  IN USE  $n  (dispatch in flight, pid=$(lease_pid "$n")) — skipped"
    continue
  fi
  if armed_target "$n"; then
    echo "  SKIP    $n  (targeted by an armed gate) — not archived"
    continue
  fi
  echo "  STALE-DIAG  $n  ($reason)"
  stale_diags=$((stale_diags+1)); issues=$((issues+1))
  add_archive "$dg"
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
    b="$(basename "$f")"
    n=""
    case "$b" in
      autoreview.armed|autoplan.armed) continue ;;
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
      *) continue ;;
    esac
    [ -n "$n" ] || continue
    case " $names " in *" $n "*) ;; *) names="$names $n" ;; esac
  done
  for n in $names; do
    newest="$(newest_mtime "$n")"
    [ -n "$newest" ] || continue
    [ "$newest" -lt "$CUTOFF" ] || continue
    # Rail 1 first: a live lease wins over any mtime evidence — a resume
    # waiting inside `codex exec` may not have written a byte yet.
    if lease_live "$n"; then
      echo "  IN USE  $n  (dispatch in flight, pid=$(lease_pid "$n")) — skipped"
      continue
    fi
    if armed_target "$n"; then
      echo "  SKIP    $n  (targeted by an armed gate) — not archived"
      continue
    fi
    age_days=$(( (NOW - newest) / 86400 ))
    members="$(thread_files "$n" | sed "s|^$STATE_DIR/||" | tr '\n' ' ')"
    case "$n" in
      review|plan)
        echo "  DORMANT $n  (${age_days}d idle; generic thread — listed only, never auto-archived)"
        dormant=$((dormant+1)); issues=$((issues+1))
        continue ;;
    esac
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
  i=0
  while [ "$i" -lt "${#ARCHIVE[@]}" ]; do
    move_one "${ARCHIVE[$i]}"
    i=$((i+1))
  done
  # Dormant sets move wholesale — but re-stat first (rail 3): anything touched
  # since detection means the thread woke up; leave it alone this run.
  i=0
  while [ "$i" -lt "${#DORMANT_NAMES[@]}" ]; do
    n="${DORMANT_NAMES[$i]}"; det="${DORMANT_MTIMES[$i]}"; i=$((i+1))
    cur="$(newest_mtime "$n")"
    if [ "$cur" != "$det" ]; then
      echo "  SKIP (changed since detection): thread $n"
      continue
    fi
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      in_archive "$p" && continue   # already moved with the flat targets
      move_one "$p"
    done <<EOF
$(thread_files "$n")
EOF
  done
  echo "Archived $moved/$PLANNED item(s) to $dest (reversible — move them back to restore)."
else
  echo "Would archive $PLANNED item(s). Re-run with --apply to move them to an archive subdir (non-destructive)."
fi
