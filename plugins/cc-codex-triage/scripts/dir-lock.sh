#!/usr/bin/env bash
# Shared recoverable mkdir lock. Source this file, call dir_lock_init, then
# dir_lock_acquire / dir_lock_release_all.

DIR_LOCK=""
DIR_RECLAIM_LOCK=""
DIR_LOCK_HELD=false
DIR_RECLAIM_HELD=false

dir_lock_init() {
  DIR_LOCK="$1"
  DIR_RECLAIM_LOCK="$2"
  DIR_LOCK_HELD=false
  DIR_RECLAIM_HELD=false
}

dir_lock_mtime() {
  local value
  value="$(stat -c '%Y' "$1" 2>/dev/null)" && [ -n "$value" ] \
    && { printf '%s' "$value"; return 0; }
  stat -f '%m' "$1" 2>/dev/null
}

dir_lock_safe() {
  local lock="$1"
  [ ! -L "$lock" ] && { [ ! -e "$lock" ] || [ -d "$lock" ]; } || return 1
  [ ! -e "$lock/owner" ] || { [ ! -L "$lock/owner" ] && [ -f "$lock/owner" ]; }
}

dir_lock_stale() {
  local lock="$1" owner now modified
  owner="$(cat "$lock/owner" 2>/dev/null || true)"
  case "$owner" in
    [1-9]|[1-9][0-9]*)
      [ "${#owner}" -le 12 ] || return 0
      kill -0 "$owner" 2>/dev/null && return 1
      return 0
      ;;
    "")
      [ ! -e "$lock/owner" ] || return 0
      now="$(date +%s 2>/dev/null || true)"
      modified="$(dir_lock_mtime "$lock" || true)"
      case "$now:$modified" in :*|*:|*[!0-9:]*) return 1 ;; esac
      [ $((now - modified)) -gt 60 ]
      ;;
    *) return 0 ;;
  esac
}

dir_lock_release_one() {
  local lock="$1"
  [ ! -L "$lock" ] || return 0
  [ -d "$lock" ] || return 0
  [ ! -L "$lock/owner" ] || return 0
  [ "$(cat "$lock/owner" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$lock/owner" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}

dir_lock_release_reclaim() {
  $DIR_RECLAIM_HELD || return 0
  dir_lock_release_one "$DIR_RECLAIM_LOCK"
  DIR_RECLAIM_HELD=false
}

dir_lock_release_all() {
  dir_lock_release_reclaim
  if $DIR_LOCK_HELD; then
    dir_lock_release_one "$DIR_LOCK"
    DIR_LOCK_HELD=false
  fi
}

dir_lock_acquire_reclaim() {
  local tries=0 sampled moved stale
  while [ "$tries" -lt 100 ]; do
    dir_lock_safe "$DIR_RECLAIM_LOCK" || return 1
    if mkdir "$DIR_RECLAIM_LOCK" 2>/dev/null; then
      if (set -C; printf '%s\n' "$$" > "$DIR_RECLAIM_LOCK/owner") 2>/dev/null \
          && [ "$(cat "$DIR_RECLAIM_LOCK/owner" 2>/dev/null)" = "$$" ]; then
        DIR_RECLAIM_HELD=true
        return 0
      fi
      return 1
    fi
    if dir_lock_stale "$DIR_RECLAIM_LOCK"; then
      sampled="$(cat "$DIR_RECLAIM_LOCK/owner" 2>/dev/null || true)"
      stale="$DIR_RECLAIM_LOCK.stale.$$.$tries"
      [ ! -e "$stale" ] && [ ! -L "$stale" ] || return 1
      if mv "$DIR_RECLAIM_LOCK" "$stale" 2>/dev/null; then
        moved="$(cat "$stale/owner" 2>/dev/null || true)"
        if [ "$moved" != "$sampled" ]; then
          if [ ! -e "$DIR_RECLAIM_LOCK" ] && [ ! -L "$DIR_RECLAIM_LOCK" ]; then
            mv "$stale" "$DIR_RECLAIM_LOCK" 2>/dev/null || true
          else
            rm -f "$stale/owner" 2>/dev/null || true
            rmdir "$stale" 2>/dev/null || true
          fi
          return 1
        fi
        rm -f "$stale/owner" 2>/dev/null || true
        rmdir "$stale" 2>/dev/null || true
        tries=$((tries + 1))
        continue
      fi
    fi
    return 1
  done
  return 1
}

dir_lock_try_reclaim() {
  local owner stale moved
  dir_lock_acquire_reclaim || return 1
  if ! dir_lock_safe "$DIR_LOCK"; then
    dir_lock_release_reclaim
    return 1
  fi
  if [ ! -d "$DIR_LOCK" ]; then
    dir_lock_release_reclaim
    return 0
  fi
  owner="$(cat "$DIR_LOCK/owner" 2>/dev/null || true)"
  if ! dir_lock_stale "$DIR_LOCK"; then
    dir_lock_release_reclaim
    return 1
  fi
  stale="$DIR_LOCK.stale.$$"
  if [ -e "$stale" ] || [ -L "$stale" ]; then
    dir_lock_release_reclaim
    return 1
  fi
  if mv "$DIR_LOCK" "$stale" 2>/dev/null; then
    moved="$(cat "$stale/owner" 2>/dev/null || true)"
    if [ "$moved" != "$owner" ]; then
      if [ ! -e "$DIR_LOCK" ] && [ ! -L "$DIR_LOCK" ]; then
        mv "$stale" "$DIR_LOCK" 2>/dev/null || true
      else
        rm -f "$stale/owner" 2>/dev/null || true
        rmdir "$stale" 2>/dev/null || true
      fi
      dir_lock_release_reclaim
      return 1
    fi
    rm -f "$stale/owner" 2>/dev/null || true
    rmdir "$stale" 2>/dev/null || true
    dir_lock_release_reclaim
    return 0
  fi
  dir_lock_release_reclaim
  return 1
}

dir_lock_acquire() {
  dir_lock_safe "$DIR_LOCK" && dir_lock_safe "$DIR_RECLAIM_LOCK" || return 1
  if ! mkdir "$DIR_LOCK" 2>/dev/null; then
    dir_lock_try_reclaim && mkdir "$DIR_LOCK" 2>/dev/null || return 1
  fi
  if ! (set -C; printf '%s\n' "$$" > "$DIR_LOCK/owner") 2>/dev/null \
      || [ "$(cat "$DIR_LOCK/owner" 2>/dev/null)" != "$$" ]; then
    return 1
  fi
  DIR_LOCK_HELD=true
}

dir_lock_owned() {
  $DIR_LOCK_HELD && [ "$(cat "$DIR_LOCK/owner" 2>/dev/null)" = "$$" ]
}
