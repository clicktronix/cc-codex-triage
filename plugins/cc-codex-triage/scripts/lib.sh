#!/usr/bin/env bash
# cc-codex-triage — shared helpers for the /status and /cleanup scripts.
#
# NOTE: the Stop hook (hooks/stop-hook.sh) deliberately does NOT source this —
# it keeps its own copies so it stays dependency-free and can fail open without
# relying on any external file being present. These helpers are only for the
# user-invoked read-only scripts.

# Read a single KEY=VALUE field from an armed/state file.  $1=file $2=key
field()     { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1; }
# True if the key is present at all (distinguishes "missing" from "empty").
has_field() { grep -q "^${2}=" "$1" 2>/dev/null; }   # $1=file $2=key

# Portable file mtime. GNU FIRST, load-bearing: on GNU coreutils `-f` means
# --file-system, so a BSD-first probe SUCCEEDS on Linux and prints multi-line
# filesystem stats instead of failing through.
_mtime() {
  local v
  v="$(stat -c '%y' "$1" 2>/dev/null)" && [ -n "$v" ] && { printf '%s' "${v%.*}" | tr -d '\t\n'; return 0; }
  stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null | tr -d '\t\n'
}
# Same, but as epoch seconds — for age comparisons (BSD find has no -newermt).
_mtime_epoch() {
  local v
  v="$(stat -c '%Y' "$1" 2>/dev/null)" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  stat -f '%m' "$1" 2>/dev/null
}

# The code state a gate compares against: what it last RELEASED, else the state
# at arming. Empty for a pre-0.9 armed file, which uses the dirty-tree test
# until its first release. Mirrors gate_baseline() in hooks/stop-hook.sh, which
# keeps its own copy on purpose — change both.  $1=armed file
gate_baseline() {
  local v
  v="$(field "$1" released_fp)"
  [ -n "$v" ] || v="$(field "$1" fp_at_arming)"
  printf '%s' "$v"
}
