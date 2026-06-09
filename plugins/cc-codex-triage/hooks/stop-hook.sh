#!/usr/bin/env bash
# cc-codex-triage — Stop hook for /autoreview and /autoplan self-verification.
#
# FAST and fail-open: no Codex call happens inside this hook. It only decides
# whether Claude may finish the turn, or must first run /review (or /plan) on
# its own changes. The actual review runs through the normal commands/driver.
#
# Runaway protection is layered THREE deep (any one alone terminates the loop):
#   1. stop_hook_active flag in the hook input (when Claude Code sets it).
#   2. blocks counter vs cap in the armed file (cap default 3 / 2).
#   3. autoreview: APPROVE verdict in the thread log ends blocking;
#      autoplan: one completed /plan round since arming ends blocking.
#
# Armed state (written by /autoreview, /autoplan commands):
#   .claude/codex-threads/autoreview.armed
#   .claude/codex-threads/autoplan.armed
#   KEY=VALUE lines: branch, thread, lens, cap, blocks, rounds_at_arming
#
# Output contract: JSON {"decision":"block","reason":"..."} on stdout blocks
# the stop; exit 0 with no JSON allows it. Never exit non-zero (fail-open).

set -u
INPUT="$(cat 2>/dev/null || true)"

allow() { exit 0; }

# ── defense 1: re-entrancy flag (when present) ──────────────────────────────
if command -v jq >/dev/null 2>&1; then
  [[ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)" == "true" ]] && allow
else
  printf '%s' "$INPUT" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && allow
fi

STATE_DIR=".claude/codex-threads"
[[ -d "$STATE_DIR" ]] || allow
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -z "$BRANCH" ]] && allow

read_field() { # $1=file $2=key $3=default
  local v
  v="$(sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1)"
  printf '%s' "${v:-$3}"
}

bump_blocks() { # $1=file — rewrite with blocks incremented, preserve other keys
  local f="$1" b
  b=$(( $(read_field "$f" blocks 0) + 1 ))
  {
    grep -v '^blocks=' "$f" 2>/dev/null
    echo "blocks=$b"
  } > "$f.tmp" && mv -f "$f.tmp" "$f"
  printf '%s' "$b"
}

# Reason strings are emitted into JSON — keep them free of double quotes.
emit_block() { # $1=reason
  printf '{"decision":"block","reason":"%s"}\n' "$1"
  exit 0
}

dirty_code() {
  git status --porcelain -uall 2>/dev/null | grep -vF '.claude/codex-threads/' | grep -q .
}

dirty_plans() {
  git status --porcelain -uall -- 'docs/plans' 'docs/PLANS' 2>/dev/null | grep -q .
}

last_review_verdict() { # $1=thread — standalone verdict line from the log REPLY
  tail -n 400 "$STATE_DIR/$1.log" 2>/dev/null \
    | grep -E '^[[:space:]]*(APPROVE|REQUEST_CHANGES|COMMENT)(---)?[[:space:]]*$' \
    | tail -1 | tr -d ' -' || true
}

# ── /autoreview ─────────────────────────────────────────────────────────────
AR="$STATE_DIR/autoreview.armed"
if [[ -f "$AR" ]]; then
  ar_branch="$(read_field "$AR" branch "")"
  if [[ "$ar_branch" == "$BRANCH" ]] && dirty_code; then
    thread="$(read_field "$AR" thread "review-$BRANCH")"
    lens="$(read_field "$AR" lens correctness)"
    cap="$(read_field "$AR" cap 3)"
    blocks="$(read_field "$AR" blocks 0)"
    verdict="$(last_review_verdict "$thread")"
    if [[ "$verdict" == "APPROVE" ]]; then
      : # verified — fall through to autoplan check / allow
    elif [[ "$blocks" -ge "$cap" ]]; then
      echo "autoreview: round cap ($cap) reached without APPROVE on thread $thread — letting the turn finish. See the thread log for open findings; disarm with /autoreview off or re-arm to continue." >&2
    else
      n="$(bump_blocks "$AR")"
      emit_block "autoreview armed: there are unverified code changes. Run the plugin command review with --thread $thread --lens $lens on your changes, address blocking findings per the fix-the-neighborhood rule in skill codex-triage, then finish the turn. Round $n/$cap. Disarm with the autoreview command (off)."
    fi
  fi
fi

# ── /autoplan ───────────────────────────────────────────────────────────────
AP="$STATE_DIR/autoplan.armed"
if [[ -f "$AP" ]]; then
  ap_branch="$(read_field "$AP" branch "")"
  if [[ "$ap_branch" == "$BRANCH" ]] && dirty_plans; then
    thread="$(read_field "$AP" thread "plan-$BRANCH")"
    lens="$(read_field "$AP" lens stress-test)"
    cap="$(read_field "$AP" cap 2)"
    blocks="$(read_field "$AP" blocks 0)"
    rounds_now="$(cat "$STATE_DIR/$thread.rounds" 2>/dev/null || echo 0)"
    rounds_armed="$(read_field "$AP" rounds_at_arming 0)"
    if [[ "$rounds_now" -gt "$rounds_armed" ]]; then
      : # at least one stress-test ran since arming — verified enough for the gate
    elif [[ "$blocks" -ge "$cap" ]]; then
      echo "autoplan: round cap ($cap) reached without a /plan run on thread $thread — letting the turn finish. Disarm with /autoplan off or re-arm." >&2
    else
      n="$(bump_blocks "$AP")"
      emit_block "autoplan armed: plan documents changed but have not been stress-tested. Run the plugin command plan with --thread $thread --lens $lens on the updated plan, address blocking objections, then finish the turn. Round $n/$cap. Disarm with the autoplan command (off)."
    fi
  fi
fi

allow
