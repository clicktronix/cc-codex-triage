#!/usr/bin/env bash
# Resolve persistent plugin state to the repository's common Git directory.
#
# Unlike a worktree-local .claude directory, the common Git directory survives
# removal of a disposable worktree and is shared by every worktree of the same
# repository. CC_CODEX_STATE_DIR is an explicit test/compatibility override.
#
# usage: state-dir.sh [--read-only]
set -u
umask 077

READ_ONLY=false
case "${1:-}" in
  "") ;;
  --read-only) READ_ONLY=true ;;
  *) echo "usage: state-dir.sh [--read-only]" >&2; exit 1 ;;
esac

if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "not inside a git repository" >&2
  exit 7
fi
cd "$ROOT" || exit 7

if [ -n "${CC_CODEX_STATE_DIR:-}" ]; then
  case "$CC_CODEX_STATE_DIR" in
    /*) STATE_DIR="$CC_CODEX_STATE_DIR" ;;
    *)  STATE_DIR="$ROOT/$CC_CODEX_STATE_DIR" ;;
  esac
  STATE_PARENT="$(dirname -- "$STATE_DIR")"
  [ ! -L "$STATE_PARENT" ] || { echo "refusing symlinked state parent" >&2; exit 7; }
  [ ! -L "$STATE_DIR" ] || { echo "refusing symlinked state directory" >&2; exit 7; }
  [ ! -e "$STATE_DIR" ] || [ -d "$STATE_DIR" ] \
    || { echo "state path is not a directory" >&2; exit 7; }
  $READ_ONLY || mkdir -p "$STATE_DIR" || exit 7
  printf '%s\n' "$STATE_DIR"
  exit 0
fi

COMMON_RAW="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 7
case "$COMMON_RAW" in
  /*) COMMON_DIR="$COMMON_RAW" ;;
  *)  COMMON_DIR="$ROOT/$COMMON_RAW" ;;
esac
if ! COMMON_DIR="$(cd "$COMMON_DIR" 2>/dev/null && pwd -P)" || [ -z "$COMMON_DIR" ]; then
  echo "cannot resolve the common Git directory" >&2
  exit 7
fi
STATE_DIR="$COMMON_DIR/cc-codex-triage/threads"
LEGACY_DIR="$ROOT/.claude/codex-threads"

if $READ_ONLY; then
  if [ -d "$STATE_DIR" ]; then
    printf '%s\n' "$STATE_DIR"
  elif [ -d "$LEGACY_DIR" ]; then
    # Read compatibility before the first mutating command performs migration.
    printf '%s\n' "$LEGACY_DIR"
  else
    printf '%s\n' "$STATE_DIR"
  fi
  exit 0
fi

PARENT="$COMMON_DIR/cc-codex-triage"
[ ! -L "$PARENT" ] || { echo "refusing symlinked state parent" >&2; exit 7; }
[ ! -e "$PARENT" ] || [ -d "$PARENT" ] \
  || { echo "state parent is not a directory" >&2; exit 7; }
mkdir -p "$PARENT" || exit 1
[ ! -L "$STATE_DIR" ] || { echo "refusing symlinked thread directory" >&2; exit 7; }
LOCK="$PARENT/migration.lock"
mtime_epoch() {
  v="$(stat -c '%Y' "$1" 2>/dev/null)" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  stat -f '%m' "$1" 2>/dev/null
}
i=0
while :; do
  if mkdir "$LOCK" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK/owner" || { rmdir "$LOCK" 2>/dev/null; exit 1; }
    break
  fi
  owner="$(cat "$LOCK/owner" 2>/dev/null)"
  case "$owner" in
    ''|*[!0-9]*)
      now="$(date +%s 2>/dev/null)"; mt="$(mtime_epoch "$LOCK")"
      case "$now:$mt" in :*|*:|*[!0-9:]*) ;; *)
        if [ $((now - mt)) -gt 60 ] && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
          rm -rf "$LOCK.stale.$$" 2>/dev/null
          continue
        fi
      esac
      ;;
    *)
      if ! kill -0 "$owner" 2>/dev/null && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
        rm -rf "$LOCK.stale.$$" 2>/dev/null
        continue
      fi
      ;;
  esac
  i=$((i+1))
  [ "$i" -lt 100 ] || { echo "state-dir.sh: migration lock is busy" >&2; exit 1; }
  sleep 0.05 2>/dev/null || sleep 1
done
trap 'if [ "$(cat "$LOCK/owner" 2>/dev/null)" = "$$" ]; then rm -f "$LOCK/owner"; rmdir "$LOCK" 2>/dev/null || true; fi' EXIT

# Copy under a common-Git mutex. The legacy directory is deliberately retained:
# an older installed plugin can still read it, and a collision is recoverable.
mkdir -p "$STATE_DIR" || exit 1

if [ -d "$LEGACY_DIR" ] && [ "$LEGACY_DIR" != "$STATE_DIR" ]; then
  for src in "$LEGACY_DIR"/* "$LEGACY_DIR"/.[!.]* "$LEGACY_DIR"/..?*; do
    [ -e "$src" ] || continue
    name="${src##*/}"
    case "$name" in
      autoreview.armed|autoplan.armed|gate-index|*.armed.lock|*.active|*.tmp.*) continue ;;
    esac
    if [ -L "$src" ]; then
      echo "state-dir.sh: refused symlinked legacy state at $src" >&2
      continue
    fi
    dest="$STATE_DIR/$name"
    if [ ! -e "$dest" ]; then
      cp -pR "$src" "$dest" 2>/dev/null || {
        echo "state-dir.sh: could not migrate $src" >&2
        exit 1
      }
    elif [ -f "$src" ] && [ -f "$dest" ] && ! cmp -s "$src" "$dest"; then
      echo "state-dir.sh: retained conflicting legacy state at $src" >&2
    fi
  done
fi

printf '%s\n' "$STATE_DIR"
