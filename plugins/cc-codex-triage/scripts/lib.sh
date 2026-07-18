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

# Portable file mtime (BSD/macOS `stat -f`, GNU/Linux `stat -c`).
_mtime() { stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null || { stat -c '%y' "$1" 2>/dev/null | cut -d. -f1; }; }
# Same, but as epoch seconds — for age comparisons (BSD find has no -newermt).
_mtime_epoch() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }
