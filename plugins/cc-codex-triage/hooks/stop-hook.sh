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
#   2. Success gates: autoreview releases on an APPROVE verdict in the thread
#      log; autoplan releases once a /plan round ran since arming.
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
#   KEY=VALUE lines: branch, thread, lens, cap, blocks, rounds_at_arming
#
# Output contract: JSON {"decision":"block","reason":"..."} on stdout blocks
# the stop; exit 0 with no JSON allows it. Never exit non-zero (fail-open).

set -u
# Consume stdin (hook input JSON) — must read it to avoid a broken pipe.
INPUT="$(cat 2>/dev/null || true)"
: "${INPUT:-}"

allow() { exit 0; }

STATE_DIR=".claude/codex-threads"
[[ -d "$STATE_DIR" ]] || allow
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -z "$BRANCH" ]] && allow
BRANCH_SLUG="$(printf '%s' "$BRANCH" | tr '/' '-')"

is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_thread() { [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]; }

read_field() { # $1=file $2=key $3=default
  local v
  v="$(sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1)"
  printf '%s' "${v:-$3}"
}

bump_blocks() { # $1=file $2=current — rewrite with blocks incremented
  local f="$1" b=$(( $2 + 1 ))
  {
    grep -v '^blocks=' "$f" 2>/dev/null
    echo "blocks=$b"
  } > "$f.tmp" && mv -f "$f.tmp" "$f"
  printf '%s' "$b"
}

# Reason text is interpolated into JSON: strip characters that could break it.
emit_block() { # $1=reason
  local reason
  reason="$(printf '%s' "$1" | tr -d '"\\' | tr '\n' ' ')"
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
  exit 0
}

dirty_code() {
  git status --porcelain -uall 2>/dev/null | grep -vF '.claude/codex-threads/' | grep -q .
}

dirty_plans() {
  git status --porcelain -uall -- 'docs/plans' 'docs/PLANS' 2>/dev/null | grep -q .
}

last_review_verdict() { # $1=thread — standalone verdict line from the log REPLY
  local line
  line="$(tail -n 400 "$STATE_DIR/$1.log" 2>/dev/null \
    | grep -E '^[[:space:]]*([Vv]erdict:[[:space:]]*)?(APPROVE|REQUEST_CHANGES|COMMENT)(---)?[[:space:]]*$' \
    | tail -1)"
  printf '%s' "$line" | grep -oE 'APPROVE|REQUEST_CHANGES|COMMENT' | tail -1
}

# ── /autoreview ─────────────────────────────────────────────────────────────
AR="$STATE_DIR/autoreview.armed"
if [[ -f "$AR" ]]; then
  ar_branch="$(read_field "$AR" branch "")"
  if [[ "$ar_branch" == "$BRANCH" ]] && dirty_code; then
    thread="$(read_field "$AR" thread "review-$BRANCH_SLUG")"
    is_thread "$thread" || thread="review-$BRANCH_SLUG"
    lens="$(read_field "$AR" lens correctness)"
    cap="$(read_field "$AR" cap 3)"
    blocks="$(read_field "$AR" blocks 0)"
    if ! is_num "$cap" || ! is_num "$blocks"; then
      echo "autoreview: malformed cap/blocks in $AR — failing open. Re-arm with /autoreview on." >&2
    else
      verdict="$(last_review_verdict "$thread")"
      if [[ "$verdict" == "APPROVE" ]]; then
        : # verified — release
      elif [[ "$blocks" -ge "$cap" ]]; then
        echo "autoreview: round cap ($cap) reached without APPROVE on thread $thread — letting the turn finish. See the thread log for open findings; disarm with /autoreview off or re-arm to continue." >&2
      else
        n="$(bump_blocks "$AR" "$blocks")"
        emit_block "autoreview armed: there are unverified code changes. Run the plugin command review with --thread $thread --lens $lens on your changes, address blocking findings per the fix-the-neighborhood rule in skill codex-triage, then finish the turn. Round $n/$cap. Disarm with the autoreview command (off)."
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
    cap="$(read_field "$AP" cap 2)"
    blocks="$(read_field "$AP" blocks 0)"
    rounds_now="$(cat "$STATE_DIR/$thread.rounds" 2>/dev/null || echo 0)"
    rounds_armed="$(read_field "$AP" rounds_at_arming 0)"
    if ! is_num "$cap" || ! is_num "$blocks" || ! is_num "$rounds_now" || ! is_num "$rounds_armed"; then
      echo "autoplan: malformed counters in $AP — failing open. Re-arm with /autoplan on." >&2
    # Release when the round count CHANGED since arming (not strictly greater:
    # /thread-new resets the counter below the arming snapshot, and a fresh
    # /plan run must still release the gate).
    elif [[ "$rounds_now" -ne "$rounds_armed" ]]; then
      : # at least one stress-test ran since arming — release
    elif [[ "$blocks" -ge "$cap" ]]; then
      echo "autoplan: round cap ($cap) reached without a /plan run on thread $thread — letting the turn finish. Disarm with /autoplan off or re-arm." >&2
    else
      n="$(bump_blocks "$AP" "$blocks")"
      emit_block "autoplan armed: plan documents changed but have not been stress-tested. Run the plugin command plan with --thread $thread --lens $lens on the updated plan, address blocking objections, then finish the turn. Round $n/$cap. Disarm with the autoplan command (off)."
    fi
  fi
fi

allow
