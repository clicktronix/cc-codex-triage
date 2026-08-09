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

LEGACY_DIR="$ROOT/.claude/codex-threads"
[ ! -L "$(dirname -- "$GATE_DIR")" ] || { echo "refusing symlinked gate parent" >&2; exit 7; }
[ ! -L "$GATE_DIR" ] || { echo "refusing symlinked gate directory" >&2; exit 7; }
[ ! -e "$GATE_DIR" ] || [ -d "$GATE_DIR" ] \
  || { echo "gate path is not a directory" >&2; exit 7; }
if $READ_ONLY; then
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
[ ! -L "$GATE_DIR/.legacy-migrated" ] \
  || { echo "refusing symlinked gate migration marker" >&2; exit 7; }
if [ ! -e "$GATE_DIR/.legacy-migrated" ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  for name in autoreview.armed autoplan.armed; do
    LEGACY_BRANCH="$(sed -n 's/^branch=//p' "$LEGACY_DIR/$name" 2>/dev/null | head -1)"
    # A legacy gate belongs to the worktree whose checked-out branch it names.
    # Copying it into every linked worktree would resurrect one logical gate as
    # several independent gates. Detached and mismatched worktrees mark the
    # migration complete without adopting the foreign gate.
    [ ! -L "$LEGACY_DIR/$name" ] || continue
    [ ! -L "$GATE_DIR/$name" ] \
      || { echo "refusing symlinked gate state: $GATE_DIR/$name" >&2; exit 7; }
    if [ -f "$LEGACY_DIR/$name" ] && [ ! -e "$GATE_DIR/$name" ] \
        && [ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ] \
        && [ "$LEGACY_BRANCH" = "$BRANCH" ]; then
      cp -p "$LEGACY_DIR/$name" "$GATE_DIR/$name" || exit 1
    fi
  done
  : > "$GATE_DIR/.legacy-migrated" || exit 1
fi

printf '%s\n' "$GATE_DIR"
