#!/usr/bin/env bash
# cc-codex-triage — Stop hook for /autoreview and /autoplan self-verification.
#
# FAST and fail-open: no Codex call happens inside this hook. It only decides
# whether Claude may finish the turn, or must first run /review (or /plan) on
# its own changes. The actual review runs through the normal commands/driver.
#
# Runaway protection (hard, independent of Claude Code internals):
#   1. blocks counter vs cap in the armed file — the hard terminator. The
#      counters are validated as numeric; ANY malformed value fails OPEN
#      (allow), never closed.
#   2. Success gates: autoreview releases on an APPROVE verdict appended to
#      the thread log AFTER arming (byte-offset cut); autoplan releases once
#      the thread log changed size since arming (a dispatch always appends).
#   3. Scoping: armed branch must match the current branch and the tree must
#      actually be dirty for that gate's file class.
#
# stop_hook_active is deliberately NOT an unconditional allow: honoring it
# would cap the gate at one block per user turn and silently break the
# advertised "until APPROVE or cap" contract. The numeric cap bounds total
# cost instead (at most `cap` blocks per arming).
#
# Armed state (written by /autoreview, /autoplan commands):
#   .claude/codex-threads/autoreview.armed
#   .claude/codex-threads/autoplan.armed
#   KEY=VALUE lines: branch, thread, lens, cap, blocks, log_bytes_at_arming.
#   log_bytes_at_arming is REQUIRED (missing = pre-0.5 arming = fail open):
#   autoreview parses verdicts only from log content appended after it;
#   autoplan releases when the log size differs from it.
#
# Output contract: JSON {"decision":"block","reason":"..."} on stdout blocks
# the stop; exit 0 with no JSON allows it. Never exit non-zero (fail-open).

set -u
# Consume stdin (hook input JSON) — must read it to avoid a broken pipe.
INPUT="$(cat 2>/dev/null || true)"
: "${INPUT:-}"

allow() { exit 0; }

# Anchor to the repo root: state paths are repo-relative and the session's
# Bash cwd can drift into subdirectories — without this the hook could read a
# different state dir than the driver wrote. Failure to anchor is fail-open
# (relative paths then simply find nothing).
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$ROOT" ]]; then cd "$ROOT" 2>/dev/null || true; fi

# The block reason points Claude at the command file to follow — the commands
# are disable-model-invocation, so the model cannot invoke them itself and
# needs the file path to read the steps. Derived from this script's location.
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || true)"
CMD_DIR="${PLUGIN_ROOT:+$PLUGIN_ROOT/commands}"
CMD_DIR="${CMD_DIR:-the cc-codex-triage plugin commands dir}"

STATE_DIR=".claude/codex-threads"
[[ -d "$STATE_DIR" ]] || allow
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -z "$BRANCH" ]] && allow
# Detached HEAD: rev-parse yields the literal "HEAD" — arming-branch matching
# would then bind to ANY later detached state. No branch to scope to → allow.
[[ "$BRANCH" == "HEAD" ]] && allow
# Map EVERYTHING outside the driver's thread-name alphabet to '-' — git allows
# +, #, @, " etc. in branch names, and a slug the driver rejects would make
# the gate's requested route unsatisfiable until cap.
BRANCH_SLUG="$(printf '%s' "$BRANCH" | tr -c 'a-zA-Z0-9_.-' '-')"

# Leading zeros are rejected, not just non-digits: bash [[ -ge ]] parses 08/09
# as octal and errors out — which would skew BOTH the cap comparison and the
# bump arithmetic into a fail-closed loop.
is_num() { [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]; }
is_thread() { [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]; }
# Exact allowlists (not a character-class filter): the lens lands in the block
# reason as a --lens argument, and an unknown-but-printable value would route
# the model to an invalid invocation instead of the gate's default.
is_review_lens() { case "$1" in correctness|security|performance|architecture|ux|quick) return 0;; *) return 1;; esac; }
is_plan_lens() { case "$1" in stress-test|pre-mortem|devils-advocate|alternatives|adr) return 0;; *) return 1;; esac; }

read_field() { # $1=file $2=key $3=default — for OPTIONAL fields with a safe fallback
  local v
  v="$(sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1)"
  printf '%s' "${v:-$3}"
}

raw_field() { # $1=file $2=key — for REQUIRED fields: empty when missing OR
  # present-but-empty, so `key=` cannot silently become the default and bypass
  # validation (the caller's is_num rejects empty).
  sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1
}

has_field() { grep -q "^${2}=" "$1" 2>/dev/null; } # $1=file $2=key

log_size() { # $1=thread — current byte size of the thread log, 0 if absent
  local s
  s="$(wc -c 2>/dev/null < "$STATE_DIR/$1.log" | tr -d ' ')"
  s="${s:-0}"
  is_num "$s" || s=0
  printf '%s' "$s"
}

bump_blocks() { # $1=file $2=current — rewrite with blocks incremented.
  # Returns non-zero if the increment could NOT be persisted (e.g. read-only
  # state dir). The caller must then fail OPEN: blocking without a persisted
  # counter would bypass the cap into unlimited blocking.
  local f="$1" b=$(( $2 + 1 ))
  {
    grep -v '^blocks=' "$f" 2>/dev/null
    echo "blocks=$b"
  } > "$f.tmp" && mv -f "$f.tmp" "$f" || return 1
  printf '%s' "$b"
}

# Reason text is interpolated into JSON: strip quotes/backslashes, and map ALL
# control characters (not just newline — a tab or CR is just as illegal in a
# JSON string) to spaces.
emit_block() { # $1=reason
  local reason
  reason="$(printf '%s' "$1" | tr -d '"\\' | tr -s '[:cntrl:]' ' ')"
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
  exit 0
}

dirty_code() {
  git status --porcelain -uall 2>/dev/null | grep -vF '.claude/codex-threads/' | grep -q .
}

dirty_plans() {
  # Plan-doc locations are configurable via CC_CODEX_PLAN_PATHS (space-separated
  # pathspecs); defaults to the two conventional dirs. Word-splitting of the
  # variable into separate pathspecs is intentional.
  local paths="${CC_CODEX_PLAN_PATHS:-docs/plans docs/PLANS}"
  # shellcheck disable=SC2086
  git status --porcelain -uall -- $paths 2>/dev/null | grep -q .
}

last_review_verdict() { # $1=thread $2=byte offset of the log at arming time.
  # Standalone verdict line from REPLY sections ONLY, and only from log content
  # APPENDED AFTER ARMING. Two protections in one:
  #   - section tracking: the driver writes column-0 markers (PROMPT:/REPLY:/
  #     ---/[timestamp]) and indents body lines by two spaces, so a verdict
  #     literal inside a logged PROMPT (e.g. a /reply quoting "earlier you
  #     said: APPROVE") can never release the gate;
  #   - the arming offset: a stale pre-arming APPROVE can never release, even
  #     if later non-verdict rounds (a /reply) bump the round counter.
  # No line-count window: a single long reply cannot push its verdict out of
  # scope. tail -c may start mid-line/mid-section; until a column-0 REPLY:
  # marker is seen, lines are conservatively ignored (blocks toward the cap,
  # never falsely releases).
  local log="$STATE_DIR/$1.log" off="${2:-0}" size
  [[ -f "$log" ]] || return 0
  size="$(wc -c 2>/dev/null < "$log" | tr -d ' ')"
  is_num "$size" || size=0
  # Log smaller than the arming offset = rotated or reset since arming; all
  # surviving content is post-arming, so parse the whole current log.
  [[ "$size" -lt "$off" ]] && off=0
  tail -c +"$(( off + 1 ))" "$log" 2>/dev/null | awk '
    /^REPLY:/            { r = 1; next }
    /^(PROMPT:|---$|\[)/ { r = 0; next }
    r && /^[[:space:]]*([Vv]erdict:[[:space:]]*)?(APPROVE|REQUEST_CHANGES|COMMENT)(---)?[[:space:]]*$/ { v = $0 }
    END { if (v != "") print v }
  ' | grep -oE 'APPROVE|REQUEST_CHANGES|COMMENT' | tail -1
}

# ── /autoreview ─────────────────────────────────────────────────────────────
AR="$STATE_DIR/autoreview.armed"
if [[ -f "$AR" ]]; then
  ar_branch="$(read_field "$AR" branch "")"
  if [[ "$ar_branch" == "$BRANCH" ]] && dirty_code; then
    thread="$(read_field "$AR" thread "review-$BRANCH_SLUG")"
    is_thread "$thread" || thread="review-$BRANCH_SLUG"
    lens="$(read_field "$AR" lens correctness)"
    is_review_lens "$lens" || lens=correctness
    cap="$(raw_field "$AR" cap)"
    blocks="$(raw_field "$AR" blocks)"
    log_off="$(raw_field "$AR" log_bytes_at_arming)"
    # A missing offset is NOT a zero offset: a pre-0.5 armed file lacks the
    # field, and defaulting to 0 would scan the whole log — re-opening the
    # stale-APPROVE hole exactly on upgrade. Missing field = fail open.
    if ! has_field "$AR" log_bytes_at_arming; then
      echo "autoreview: armed file has no log_bytes_at_arming (pre-0.5 arming) — failing open. Re-arm with /autoreview on." >&2
    elif ! is_num "$cap" || ! is_num "$blocks" || ! is_num "$log_off"; then
      echo "autoreview: malformed counters in $AR — failing open. Re-arm with /autoreview on." >&2
    else
      verdict="$(last_review_verdict "$thread" "$log_off")"
      # The offset cut makes the verdict self-sufficient: an APPROVE can only
      # come from log content appended after arming, which itself proves a
      # post-arming round ran. No .rounds-based second check — that counter is
      # reset by /thread-new, so it can both fake a run (reset alone changes
      # it) and mask one (reset + one run collides with the snapshot).
      if [[ "$verdict" == "APPROVE" ]]; then
        : # APPROVE earned since arming — release
      elif [[ "$blocks" -ge "$cap" ]]; then
        echo "autoreview: round cap ($cap) reached without APPROVE on thread $thread — letting the turn finish. See the thread log for open findings; disarm with /autoreview off or re-arm to continue." >&2
      elif n="$(bump_blocks "$AR" "$blocks")"; then
        emit_block "autoreview armed: there are unverified code changes. Read $CMD_DIR/review.md and follow its steps to review your changes with --thread $thread --lens $lens. Validate each finding against the code before applying it, and fix the neighborhood of valid ones, per skill codex-triage. Then finish the turn. Round $n/$cap. Disarm with the autoreview command (off)."
      else
        echo "autoreview: could not persist the blocks counter (state dir not writable?) — failing open; an unpersisted counter would bypass the cap into unlimited blocking." >&2
      fi
    fi
  fi
fi

# ── /autoplan ───────────────────────────────────────────────────────────────
AP="$STATE_DIR/autoplan.armed"
if [[ -f "$AP" ]]; then
  ap_branch="$(read_field "$AP" branch "")"
  if [[ "$ap_branch" == "$BRANCH" ]] && dirty_plans; then
    thread="$(read_field "$AP" thread "plan-$BRANCH_SLUG")"
    is_thread "$thread" || thread="plan-$BRANCH_SLUG"
    lens="$(read_field "$AP" lens stress-test)"
    is_plan_lens "$lens" || lens=stress-test
    cap="$(raw_field "$AP" cap)"
    blocks="$(raw_field "$AP" blocks)"
    log_off="$(raw_field "$AP" log_bytes_at_arming)"
    log_now="$(log_size "$thread")"
    if ! has_field "$AP" log_bytes_at_arming; then
      echo "autoplan: armed file has no log_bytes_at_arming (pre-0.5 arming) — failing open. Re-arm with /autoplan on." >&2
    elif ! is_num "$cap" || ! is_num "$blocks" || ! is_num "$log_off"; then
      echo "autoplan: malformed counters in $AP — failing open. Re-arm with /autoplan on." >&2
    # Release when the thread log changed size since arming: ANY dispatch to
    # the plan thread appends (normally the requested /plan run — the gate
    # detects log growth, not command identity; documented in autoplan.md).
    # Unlike the .rounds counter, the log is NOT touched by /thread-new — a
    # bare reset cannot fake a dispatch, and a post-reset run cannot collide
    # with the snapshot. Known cap-bounded edge (both gates): a post-arming
    # rotation that leaves the current log EXACTLY equal in size to the
    # snapshot reads as "no dispatch" — fails toward blocking, never toward a
    # false release, and the cap terminates it.
    elif [[ "$log_now" -ne "$log_off" ]]; then
      : # at least one post-arming dispatch on the plan thread — release
    elif [[ "$blocks" -ge "$cap" ]]; then
      echo "autoplan: round cap ($cap) reached without a post-arming dispatch on thread $thread — letting the turn finish. Disarm with /autoplan off or re-arm." >&2
    elif n="$(bump_blocks "$AP" "$blocks")"; then
      emit_block "autoplan armed: plan documents changed but have not been stress-tested. Read $CMD_DIR/plan.md and follow its steps to stress-test the updated plan with --thread $thread --lens $lens, address blocking objections, then finish the turn. Round $n/$cap. Disarm with the autoplan command (off)."
    else
      echo "autoplan: could not persist the blocks counter (state dir not writable?) — failing open; an unpersisted counter would bypass the cap into unlimited blocking." >&2
    fi
  fi
fi

allow
