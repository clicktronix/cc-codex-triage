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

# Portable file mtime. GNU IS TRIED FIRST, and the order is load-bearing: on
# GNU coreutils `-f` means --file-system, so the BSD form does not fail on
# Linux — it SUCCEEDS and prints filesystem statistics, multi-line and with
# embedded spaces. A BSD-first probe therefore returns garbage on Linux rather
# than falling through, which silently corrupted every mtime column and, in the
# TSV listing, the record structure itself.
_mtime() {
  local v
  v="$(stat -c '%y' "$1" 2>/dev/null)" && [ -n "$v" ] && { printf '%s' "${v%.*}" | tr -d '\t\n'; return 0; }
  stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null | tr -d '\t\n'
}
# Same, but as epoch seconds — for age comparisons (BSD find has no -newermt).
# `-f '%m'` is unambiguous (GNU --file-system takes no format), but keep the
# same order for consistency.
_mtime_epoch() {
  local v
  v="$(stat -c '%Y' "$1" 2>/dev/null)" && [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  stat -f '%m' "$1" 2>/dev/null
}

# The code state a gate compares against: what it last RELEASED, else the state
# captured at arming. Empty for a pre-0.9 armed file, which still uses the
# dirty-tree test until its first release. Mirrors gate_baseline() in
# hooks/stop-hook.sh — the hook keeps its own copy on purpose (see the note at
# the top of this file); this one exists so /status and /cleanup do not each
# reinvent the rule and drift from the gate they report on.  $1=armed file
gate_baseline() {
  local v
  v="$(field "$1" released_fp)"
  [ -n "$v" ] || v="$(field "$1" fp_at_arming)"
  printf '%s' "$v"
}
