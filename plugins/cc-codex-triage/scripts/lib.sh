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

# Per-file mkdir mutex for armed-gate state. Every writer rewrites the WHOLE
# file, so an unserialized one drops what a concurrent writer just put there.
# The Stop hook keeps its OWN copy — it must stay sourceless — so there are two
# implementations, not one per script. Keep them in step.
#
# The token is per-process AND random: PIDs are recycled, and it has to tell our
# lock from a replacement. A lock older than 30 s is stale by construction; the
# steal is gated on an unchanged mtime (a replacement is newer) and done with an
# atomic `mv`, and release only ever removes a lock we still own — an owner that
# stalled past the window and resumed must not delete its replacement's.
ARMED_LOCK_TOKEN="$$.${RANDOM:-0}${RANDOM:-0}"

armed_lock() {   # $1=armed file -> 0 if held
  local d="$1.lock" i=0 now m1 m2 owner opid
  while [ "$i" -lt 25 ]; do
    if mkdir "$d" 2>/dev/null; then
      # Test seam for the exact pre-token race: the directory can be reclaimed
      # and replaced while this process is paused between mkdir and publication.
      [ -n "${CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK:-}" ] \
        && . "$CC_ARMED_LOCK_TEST_PRE_TOKEN_HOOK"
      # The token MUST land, or ownership cannot be proven before writing.
      # Noclobber is load-bearing: if a reclaimer already published the
      # replacement generation's owner, a resumed pre-token acquirer must lose
      # without overwriting or removing that foreign generation.
      if ! (set -C; printf '%s' "$ARMED_LOCK_TOKEN" > "$d/owner") 2>/dev/null \
          || [ "$(cat "$d/owner" 2>/dev/null)" != "$ARMED_LOCK_TOKEN" ]; then
        return 1
      fi
      return 0
    fi
    if [ "$(( i % 5 ))" -eq 0 ]; then
      now="$(date +%s 2>/dev/null)" || return 1
      m1="$(_mtime_epoch "$d")"
      case "${m1:-}" in ''|*[!0-9]*) m1="" ;; esac
      if [ -n "$m1" ] && [ "$(( now - m1 ))" -gt 30 ]; then
        # A LIVE holder is slow, not dead — evicting it hands two writers the
        # same lock.
        owner="$(cat "$d/owner" 2>/dev/null)"
        opid="${owner%%.*}"
        case "$opid" in ''|*[!0-9]*) opid="" ;; esac
        if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then
          sleep 0.05 2>/dev/null || sleep 1
          i=$((i+1)); continue
        fi
        m2="$(_mtime_epoch "$d")"
        if [ "$m1" = "$m2" ] && mv "$d" "$d.stale.$$" 2>/dev/null; then
          rm -rf "$d.stale.$$" 2>/dev/null
        fi
        i=$((i+1)); continue
      fi
    fi
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i+1))
  done
  return 1
}

# Do we STILL hold it? Checked before a write: an owner evicted after stalling
# must not overwrite the new owner's state.
armed_owned() { [ "$(cat "$1.lock/owner" 2>/dev/null)" = "$ARMED_LOCK_TOKEN" ]; }

armed_unlock() { # $1=armed file — releases ONLY our own lock
  [ "$(cat "$1.lock/owner" 2>/dev/null)" = "$ARMED_LOCK_TOKEN" ] || return 0
  rm -rf "$1.lock" 2>/dev/null
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
