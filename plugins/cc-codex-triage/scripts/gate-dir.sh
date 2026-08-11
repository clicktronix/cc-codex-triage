#!/usr/bin/env bash
# Resolve worktree-owned gate state. Unlike shared threads, armed gates and
# the fingerprint index belong to one concrete working tree.
# usage: gate-dir.sh [--read-only]
#        gate-dir.sh --registry-path   # internal: common lock target
set -u
umask 077

READ_ONLY=false
REGISTRY_PATH_ONLY=false
case "${1:-}" in
  "") ;;
  --read-only) READ_ONLY=true ;;
  --registry-path) REGISTRY_PATH_ONLY=true ;;
  *) echo "usage: gate-dir.sh [--read-only|--registry-path]" >&2; exit 1 ;;
esac

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/lib.sh"

if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
    || [ -z "$ROOT" ]; then
  echo "not inside a git repository" >&2
  exit 7
fi
cd "$ROOT" || exit 7

COMMON_RAW="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 7
case "$COMMON_RAW" in
  /*) COMMON_DIR="$COMMON_RAW" ;;
  *)  COMMON_DIR="$ROOT/$COMMON_RAW" ;;
esac
COMMON_DIR="$(cd "$COMMON_DIR" 2>/dev/null && pwd -P)" || exit 7
REGISTRY_PARENT="$COMMON_DIR/cc-codex-triage"
GATE_REGISTRY="$REGISTRY_PARENT/gate-registry"
if $REGISTRY_PATH_ONLY; then
  printf '%s\n' "$GATE_REGISTRY"
  exit 0
fi

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
  # Directory creation is not migration completion. A migrator can be paused
  # or can crash after mkdir but before copying the legacy gate and publishing
  # the marker. Until that marker exists, legacy remains the readable source.
  if [ -d "$LEGACY_DIR" ]; then
    printf '%s\n' "$LEGACY_DIR"
  else
    printf '%s\n' "$GATE_DIR"
  fi
  exit 0
fi

REGISTRY_HELD=false
MIGRATION_SOURCE_LOCK=""
MIGRATION_DEST_LOCK=""
internal_armed_lock() {
  local target="$1" original_hook original_hook_set=false rc=0
  # This script's locks protect registry/migration internals. Keep the generic
  # armed-file pre-token seam attached to the Stop-hook and gate-state writers
  # it was designed to exercise.
  original_hook="${CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK:-}"
  [ "${CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK+x}" = x ] && original_hook_set=true
  unset CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK
  armed_lock "$target" || rc=$?
  if $original_hook_set; then
    CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK="$original_hook"
    export CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK
  else
    unset CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK
  fi
  return "$rc"
}
release_gate_migration_locks() {
  [ -z "$MIGRATION_DEST_LOCK" ] || armed_unlock "$MIGRATION_DEST_LOCK"
  [ -z "$MIGRATION_SOURCE_LOCK" ] || armed_unlock "$MIGRATION_SOURCE_LOCK"
  $REGISTRY_HELD && armed_unlock "$GATE_REGISTRY"
  MIGRATION_DEST_LOCK=""
  MIGRATION_SOURCE_LOCK=""
  REGISTRY_HELD=false
}
trap release_gate_migration_locks EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ ! -L "$REGISTRY_PARENT" ] || { echo "refusing symlinked gate registry parent" >&2; exit 7; }
[ ! -e "$REGISTRY_PARENT" ] || [ -d "$REGISTRY_PARENT" ] \
  || { echo "gate registry parent is not a directory" >&2; exit 7; }
mkdir -p "$REGISTRY_PARENT" || exit 1
[ ! -L "$GATE_REGISTRY.lock" ] \
  || { echo "refusing symlinked gate registry lock" >&2; exit 7; }
internal_armed_lock "$GATE_REGISTRY" \
  || { echo "gate registry is busy; retry shortly" >&2; exit 2; }
REGISTRY_HELD=true
armed_owned "$GATE_REGISTRY" \
  || { echo "lost gate registry ownership" >&2; exit 2; }

mkdir -p "$GATE_DIR" || exit 1
[ -n "${CC_GATE_DIR_TEST_AFTER_REGISTRY_LOCK_HOOK:-}" ] \
  && . "$CC_GATE_DIR_TEST_AFTER_REGISTRY_LOCK_HOOK"
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
      MIGRATION_SOURCE_LOCK="$LEGACY_DIR/$name"
      MIGRATION_DEST_LOCK="$GATE_DIR/$name"
      internal_armed_lock "$MIGRATION_SOURCE_LOCK" || exit 2
      internal_armed_lock "$MIGRATION_DEST_LOCK" || exit 2
      armed_owned "$GATE_REGISTRY" && armed_owned "$MIGRATION_SOURCE_LOCK" \
        && armed_owned "$MIGRATION_DEST_LOCK" || exit 2
      # Re-check after both gate-file mutexes: a Stop-hook writer may have
      # changed the legacy source while this migrator waited.
      LEGACY_BRANCH="$(sed -n 's/^branch=//p' "$LEGACY_DIR/$name" 2>/dev/null | head -1)"
      if [ -f "$LEGACY_DIR/$name" ] && [ ! -e "$GATE_DIR/$name" ] \
          && [ "$LEGACY_BRANCH" = "$BRANCH" ]; then
        gate_tmp="$(mktemp "$GATE_DIR/$name.tmp.XXXXXX")" || exit 1
        if cp -p "$LEGACY_DIR/$name" "$gate_tmp" \
            && mv "$gate_tmp" "$GATE_DIR/$name"; then
          :
        else
          rm -f "$gate_tmp" 2>/dev/null
          exit 1
        fi
      fi
      armed_unlock "$MIGRATION_DEST_LOCK"
      armed_unlock "$MIGRATION_SOURCE_LOCK"
      MIGRATION_DEST_LOCK=""
      MIGRATION_SOURCE_LOCK=""
    fi
  done
  armed_owned "$GATE_REGISTRY" || { echo "lost gate registry ownership" >&2; exit 2; }
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
