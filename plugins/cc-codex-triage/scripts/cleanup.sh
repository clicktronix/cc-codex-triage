#!/usr/bin/env bash
# cc-codex-triage — /cleanup: find and (optionally) archive stale state.
#
# Default is a DRY RUN: it only lists what it found. With --apply it MOVES the
# stale items into an archive subdir (never deletes), so nothing is lost and the
# action is reversible by moving them back.
#
# Detects:
#   - stale armed gates  : autoreview/autoplan armed for a branch != current.
#   - pre-0.5 armed gates : armed files missing log_bytes_at_arming (fail-open).
#   - orphan logs         : <thread>.log with no <thread>.id (never persisted).
#   - generic threads     : `review`/`plan` default threads (contamination risk).

set -u

# Shared helpers (field / has_field). Resolve the script's own dir BEFORE the
# cd below so the source path stays valid regardless of caller cwd.
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SELF_DIR/lib.sh"

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" 2>/dev/null || true
STATE_DIR=".claude/codex-threads"

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

[ -d "$STATE_DIR" ] || { echo "No state directory ($STATE_DIR) — nothing to clean."; exit 0; }
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

# Collect targets to archive (stale/broken armed files + orphan thread files).
declare -a ARCHIVE=()
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
  $stale && ARCHIVE+=("$f")
done
[ "$shown" = 0 ] && echo "  (no armed gates)"

echo
echo "Orphan logs (a .log with no matching .id — never persisted):"
orphans=0
for lg in "$STATE_DIR"/*.log; do
  [ -f "$lg" ] || continue
  n="$(basename "$lg" .log)"
  if [ ! -f "$STATE_DIR/$n.id" ]; then
    echo "  ORPHAN  $n  (size $(wc -c < "$lg" 2>/dev/null | tr -d ' ') bytes)"
    orphans=$((orphans+1)); issues=$((issues+1))
    ARCHIVE+=("$lg")
    for ext in rounds last-error.jsonl findings.jsonl scope approved; do
      [ -f "$STATE_DIR/$n.$ext" ] && ARCHIVE+=("$STATE_DIR/$n.$ext")
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
  case " $seen " in *" $n "*) ;; *) echo "  ORPHAN  $n  (sidecar, no .log/.id)"; orphans=$((orphans+1)); issues=$((issues+1)); seen="$seen $n" ;; esac
  ARCHIVE+=("$sc")
done
[ "$orphans" = 0 ] && echo "  (none)"

echo
echo "Generic threads (contamination risk — one name reused across tasks):"
generic=0
for n in review plan; do
  [ -f "$STATE_DIR/$n.id" ] && { echo "  GENERIC $n  (prefer per-task threads: review-<branch> / plan-<topic>)"; generic=$((generic+1)); }
done
[ "$generic" = 0 ] && echo "  (none)"
# Generic threads are NOT auto-archived — they may be active. Listed only.

echo
if [ "${#ARCHIVE[@]}" -eq 0 ]; then
  echo "Nothing to archive. ${issues} note(s) above."
  exit 0
fi

if [ "$APPLY" = true ]; then
  # Unique dir (mktemp) so a second run in the same second can't reuse it; no
  # `mv -f` and an explicit name-clash skip so the "never deletes/overwrites"
  # contract holds; count only successful moves.
  dest="$(mktemp -d "$STATE_DIR/.archive-$(date +%Y%m%d-%H%M%S)-XXXXXX")" || { echo "ERROR: could not create archive dir"; exit 1; }
  moved=0
  for p in "${ARCHIVE[@]}"; do
    [ -e "$p" ] || continue
    b="$(basename "$p")"
    if [ -e "$dest/$b" ]; then echo "  SKIP (name clash, not overwritten): $b"; continue; fi
    if mv "$p" "$dest/"; then moved=$((moved+1)); echo "  archived: $b"; else echo "  FAILED to move: $b"; fi
  done
  echo "Archived $moved/${#ARCHIVE[@]} item(s) to $dest (reversible — move them back to restore)."
else
  echo "Would archive ${#ARCHIVE[@]} item(s). Re-run with --apply to move them to an archive subdir (non-destructive)."
fi
