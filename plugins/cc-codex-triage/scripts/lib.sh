#!/usr/bin/env bash
# Small read-only helpers shared by status and thread-index.

_mtime() {
  local value
  value="$(stat -c '%y' "$1" 2>/dev/null)" && [ -n "$value" ] \
    && { printf '%s' "${value%.*}" | tr -d '\t\n'; return 0; }
  stat -f '%Sm' -t '%Y-%m-%d\ %H:%M' "$1" 2>/dev/null | tr -d '\t\n'
}

live_lease() {
  local pid
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  pid="$(cat "$1")" || return 1
  case "$pid" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#pid}" -le 12 ] && kill -0 "$pid" 2>/dev/null
}
