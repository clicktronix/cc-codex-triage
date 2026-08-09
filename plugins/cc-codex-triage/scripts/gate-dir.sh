#!/usr/bin/env bash
# Resolve worktree-owned gate state. Unlike shared threads, armed gates and
# the fingerprint index belong to one concrete working tree.
# usage: gate-dir.sh [--read-only]
set -u
umask 077

READ_ONLY=false
case "${1:-}" in
  "") ;;
  --read-only) READ_ONLY=true ;;
  *) echo "usage: gate-dir.sh [--read-only]" >&2; exit 1 ;;
esac

if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
    || [ -z "$ROOT" ]; then
  echo "not inside a git repository" >&2
  exit 7
fi
cd "$ROOT" || exit 7

if [ -n "${CC_CODEX_GATE_DIR:-}" ]; then
  case "$CC_CODEX_GATE_DIR" in
    /*) GATE_DIR="$CC_CODEX_GATE_DIR" ;;
    *)  GATE_DIR="$ROOT/$CC_CODEX_GATE_DIR" ;;
  esac
else
  GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit 7
  GATE_DIR="$GIT_DIR/cc-codex-triage/gates"
fi

LEGACY_PARENT="$ROOT/.claude"
LEGACY_DIR="$LEGACY_PARENT/codex-threads"
[ ! -L "$LEGACY_PARENT" ] || { echo "refusing symlinked legacy gate parent" >&2; exit 7; }
[ ! -e "$LEGACY_PARENT" ] || [ -d "$LEGACY_PARENT" ] \
  || { echo "legacy gate parent is not a directory" >&2; exit 7; }
[ ! -L "$LEGACY_DIR" ] || { echo "refusing symlinked legacy gate directory" >&2; exit 7; }
if [ -d "$LEGACY_DIR" ]; then
  LEGACY_PHYSICAL="$(cd "$LEGACY_DIR" 2>/dev/null && pwd -P)" || exit 7
  [ "$LEGACY_PHYSICAL" = "$LEGACY_DIR" ] \
    || { echo "legacy gate state resolves outside its repository path" >&2; exit 7; }
fi
preflight_legacy_gates() {
  [ -d "$LEGACY_DIR" ] || return 0
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  for gate_name in autoreview.armed autoplan.armed; do
    legacy_gate="$LEGACY_DIR/$gate_name"
    shared_gate="$GATE_DIR/$gate_name"
    [ ! -L "$legacy_gate" ] \
      || { echo "refusing symlinked legacy gate state: $legacy_gate" >&2; return 7; }
    [ ! -e "$legacy_gate" ] || [ -f "$legacy_gate" ] \
      || { echo "legacy gate state is not a regular file: $legacy_gate" >&2; return 7; }
    [ ! -L "$shared_gate" ] \
      || { echo "refusing symlinked shared gate state: $shared_gate" >&2; return 7; }
    [ ! -e "$shared_gate" ] || [ -f "$shared_gate" ] \
      || { echo "shared gate state is not a regular file: $shared_gate" >&2; return 7; }
    legacy_branch="$(sed -n 's/^branch=//p' "$LEGACY_DIR/$gate_name" 2>/dev/null | head -1)"
    if [ -f "$LEGACY_DIR/$gate_name" ] && [ -e "$GATE_DIR/$gate_name" ] \
        && [ -n "$current_branch" ] && [ "$current_branch" != HEAD ] \
        && [ "$legacy_branch" = "$current_branch" ] \
        && ! cmp -s "$LEGACY_DIR/$gate_name" "$GATE_DIR/$gate_name"; then
      echo "conflicting legacy gate state: $LEGACY_DIR/$gate_name" >&2
      return 7
    fi
  done
}
[ ! -L "$(dirname -- "$GATE_DIR")" ] || { echo "refusing symlinked gate parent" >&2; exit 7; }
[ ! -L "$GATE_DIR" ] || { echo "refusing symlinked gate directory" >&2; exit 7; }
[ ! -e "$GATE_DIR" ] || [ -d "$GATE_DIR" ] \
  || { echo "gate path is not a directory" >&2; exit 7; }
MIGRATION_MARKER="$GATE_DIR/.legacy-migrated"
gate_migration_complete() {
  [ ! -L "$MIGRATION_MARKER" ] \
    || { echo "refusing symlinked gate migration marker" >&2; exit 7; }
  [ ! -e "$MIGRATION_MARKER" ] || [ -f "$MIGRATION_MARKER" ] \
    || { echo "gate migration marker is not a regular file" >&2; exit 7; }
  [ -f "$MIGRATION_MARKER" ]
}
if $READ_ONLY; then
  if gate_migration_complete; then
    printf '%s\n' "$GATE_DIR"
    exit 0
  fi
  preflight_legacy_gates || exit $?
  if [ -d "$GATE_DIR" ]; then
    printf '%s\n' "$GATE_DIR"
  elif [ -d "$LEGACY_DIR" ]; then
    printf '%s\n' "$LEGACY_DIR"
  else
    printf '%s\n' "$GATE_DIR"
  fi
  exit 0
fi

mkdir -p "$GATE_DIR" || exit 1
if ! gate_migration_complete; then
  preflight_legacy_gates || exit $?
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  for name in autoreview.armed autoplan.armed; do
    LEGACY_BRANCH="$(sed -n 's/^branch=//p' "$LEGACY_DIR/$name" 2>/dev/null | head -1)"
    # A legacy gate belongs to the worktree whose checked-out branch it names.
    # Copying it into every linked worktree would resurrect one logical gate as
    # several independent gates. Detached and mismatched worktrees mark the
    # migration complete without adopting the foreign gate.
    if [ -f "$LEGACY_DIR/$name" ] && [ ! -e "$GATE_DIR/$name" ] \
        && [ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ] \
        && [ "$LEGACY_BRANCH" = "$BRANCH" ]; then
      cp -p "$LEGACY_DIR/$name" "$GATE_DIR/$name" || exit 1
    fi
  done
  marker_tmp="$MIGRATION_MARKER.tmp.$$"
  [ ! -e "$marker_tmp" ] && [ ! -L "$marker_tmp" ] \
    || { echo "gate migration marker temporary path exists" >&2; exit 7; }
  if (set -C; printf 'version=1\n' > "$marker_tmp") 2>/dev/null \
      && ln "$marker_tmp" "$MIGRATION_MARKER" 2>/dev/null; then
    rm -f "$marker_tmp"
    :
  elif [ -f "$MIGRATION_MARKER" ] && [ ! -L "$MIGRATION_MARKER" ]; then
    rm -f "$marker_tmp"
  else
    rm -f "$marker_tmp" 2>/dev/null
    echo "could not publish gate migration marker" >&2
    exit 1
  fi
fi

printf '%s\n' "$GATE_DIR"
