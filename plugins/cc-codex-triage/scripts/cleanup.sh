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

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" 2>/dev/null || true
STATE_DIR=".claude/codex-threads"

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

field()     { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1; }
has_field() { grep -q "^${2}=" "$1" 2>/dev/null; }

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
    [ -f "$STATE_DIR/$n.rounds" ] && ARCHIVE+=("$STATE_DIR/$n.rounds")
    [ -f "$STATE_DIR/$n.last-error.jsonl" ] && ARCHIVE+=("$STATE_DIR/$n.last-error.jsonl")
  fi
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
  dest="$STATE_DIR/.archive-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dest"
  for p in "${ARCHIVE[@]}"; do
    [ -e "$p" ] && mv -f "$p" "$dest/" && echo "  archived: $(basename "$p")"
  done
  echo "Moved ${#ARCHIVE[@]} item(s) to $dest (reversible — move them back to restore)."
else
  echo "Would archive ${#ARCHIVE[@]} item(s). Re-run with --apply to move them to an archive subdir (non-destructive)."
fi
