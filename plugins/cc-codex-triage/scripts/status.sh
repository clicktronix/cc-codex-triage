#!/usr/bin/env bash
# cc-codex-triage — /status: one-screen view of thread + gate state.
#
# READ-ONLY: never writes or mutates any state (safe to run any time). It
# surfaces exactly the things that used to require hand-reading .armed/.rounds/
# .log + git: current branch, dirty tree, armed gates (with stale-branch /
# pre-0.5 / missing-target warnings), last verdict per thread, gitignore status,
# and the Codex CLI version vs the required minimum.

set -u

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" 2>/dev/null || true
STATE_DIR=".claude/codex-threads"
REQUIRED_CODEX="0.137.0"

# Portable mtime (BSD/macOS `stat -f`, GNU/Linux `stat -c`).
_mtime() { stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null || { stat -c '%y' "$1" 2>/dev/null | cut -d. -f1; }; }
field()     { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1; }
has_field() { grep -q "^${2}=" "$1" 2>/dev/null; }

# Last standalone verdict from a thread log — REPLY sections only, whole log
# (same marker/section rules as the Stop hook, minus the arming offset since
# this is informational). Prints '-' when none.
last_verdict() {
  local log="$STATE_DIR/$1.log"
  [ -f "$log" ] || { printf '%s' '-'; return; }
  local v
  v="$(awk '
    /^REPLY:/            { r=1; next }
    /^(PROMPT:|---$|\[)/ { r=0; next }
    r && /^[[:space:]]*([Vv]erdict:[[:space:]]*)?(APPROVE|REQUEST_CHANGES|COMMENT)(---)?[[:space:]]*$/ { v=$0 }
    END { if (v!="") print v }
  ' "$log" | grep -oE 'APPROVE|REQUEST_CHANGES|COMMENT' | tail -1)"
  printf '%s' "${v:--}"
}

IN_GIT=false; git rev-parse --show-toplevel >/dev/null 2>&1 && IN_GIT=true
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(no git)')"

echo "cc-codex-triage status"
echo "  repo branch : $BRANCH"

if $IN_GIT; then
  code_changes=$(git status --porcelain -uall 2>/dev/null | grep -vF "$STATE_DIR/" | grep -c . | tr -d ' ')
  plan_paths="${CC_CODEX_PLAN_PATHS:-docs/plans docs/PLANS}"
  # Word-split the pathspecs (intentional) but disable shell globbing so they
  # reach git unexpanded — git does its own pathspec matching. shellcheck disable=SC2086
  plan_changes=$( set -f; git status --porcelain -uall -- $plan_paths 2>/dev/null | grep -c . | tr -d ' ' )
  echo "  working tree: ${code_changes:-0} code change(s), ${plan_changes:-0} plan-doc change(s)"
fi

# Codex CLI presence + version vs the documented minimum.
if command -v codex >/dev/null 2>&1; then
  ver="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -z "$ver" ]; then
    echo "  codex CLI   : present (version unknown)"
  elif [ "$ver" = "$REQUIRED_CODEX" ]; then
    echo "  codex CLI   : $ver  (>= $REQUIRED_CODEX OK)"
  elif [ "$(printf '%s\n%s\n' "$ver" "$REQUIRED_CODEX" | sort -V | head -1)" = "$ver" ]; then
    echo "  codex CLI   : $ver  WARNING below required >= $REQUIRED_CODEX"
  else
    echo "  codex CLI   : $ver  (>= $REQUIRED_CODEX OK)"
  fi
else
  echo "  codex CLI   : NOT FOUND on PATH — install: npm install -g @openai/codex"
fi

if $IN_GIT; then
  if git check-ignore -q "$STATE_DIR/x" 2>/dev/null; then
    echo "  state dir   : gitignored OK"
  else
    echo "  state dir   : WARNING not gitignored — add '.claude/codex-threads/' to .gitignore"
  fi
fi

if [ ! -d "$STATE_DIR" ]; then
  echo
  echo "No threads or gates in this repo yet."
  exit 0
fi

# ── Armed gates ─────────────────────────────────────────────────────────────
echo
echo "Armed gates:"
shown=0
for kind in autoreview autoplan; do
  f="$STATE_DIR/$kind.armed"
  [ -f "$f" ] || continue
  shown=1
  base="${kind#auto}"   # autoreview->review, autoplan->plan
  ab="$(field "$f" branch)"; at="$(field "$f" thread)"; al="$(field "$f" lens)"
  cap="$(field "$f" cap)"; blocks="$(field "$f" blocks)"
  echo "  /$kind  branch=$ab thread=$at lens=$al  blocks used=${blocks:-?}/${cap:-?}"
  [ -n "$ab" ] && [ "$ab" != "$BRANCH" ] && \
    echo "      WARNING armed for '$ab' but you are on '$BRANCH' — gate is dormant until you switch back (it is NOT auto-cleared)."
  has_field "$f" log_bytes_at_arming || \
    echo "      WARNING pre-0.5 armed file (no log_bytes_at_arming) — the hook fails open. Re-arm with /$kind on."
  if [ -n "$at" ] && [ ! -f "$STATE_DIR/$at.log" ] && [ ! -f "$STATE_DIR/$at.id" ]; then
    echo "      WARNING target thread '$at' has no log/id on disk — the gate cannot find it. Did you run /$base with a different --thread name?"
  fi
  [ -n "$at" ] && echo "      last verdict on $at: $(last_verdict "$at")"
done
[ "$shown" = 0 ] && echo "  (none)"
echo "  note: 'cap' counts hook-blocks (gated turn-ends), NOT Codex review rounds."

# ── Threads ─────────────────────────────────────────────────────────────────
echo
echo "Threads:"
any=0
for idf in "$STATE_DIR"/*.id; do
  [ -f "$idf" ] || continue
  any=1
  n="$(basename "$idf" .id)"
  r="$(cat "$STATE_DIR/$n.rounds" 2>/dev/null || echo 0)"
  sz="$(wc -c < "$STATE_DIR/$n.log" 2>/dev/null | tr -d ' ')"
  printf '  %-30s rounds=%-3s size=%-8s last=%-16s verdict=%s\n' \
    "$n" "$r" "${sz:-0}" "$(_mtime "$idf")" "$(last_verdict "$n")"
done
[ "$any" = 0 ] && echo "  (none)"
# Explicit success — the final test above is false when threads exist, which
# would otherwise make this read-only command exit non-zero on the normal path.
exit 0
