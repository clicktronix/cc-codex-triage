#!/usr/bin/env bash
# cc-codex-triage — /status: one-screen view of thread + gate state.
#
# READ-ONLY: never writes or mutates any state (safe to run any time). It
# surfaces exactly the things that used to require hand-reading .armed/.rounds/
# .log + git: current branch, dirty tree, armed gates (with stale-branch /
# pre-0.5 / missing-target warnings), last verdict per thread, gitignore status,
# and the Codex CLI version vs the required minimum.

set -u

# Shared helpers (field / has_field / _mtime). Resolve the script's own dir
# BEFORE the cd below so the source path stays valid regardless of caller cwd.
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SELF_DIR/lib.sh"

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" 2>/dev/null || true
STATE_DIR=".claude/codex-threads"
REQUIRED_CODEX="0.137.0"   # keep in sync with the minimum stated in README.md (Prerequisites)

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
# On an unborn HEAD (git init, no commits) `rev-parse --abbrev-ref HEAD` prints
# "HEAD" to stdout AND exits non-zero — so a `|| echo …` fallback would append a
# second line. Compute it cleanly and collapse detached/unborn to one label.
if $IN_GIT; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  { [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; } && BRANCH="(detached or unborn HEAD)"
else
  BRANCH="(no git)"
fi

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
  raw="$(codex --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' | head -1)"
  core="${raw%%-*}"   # numeric x.y.z, without any -prerelease suffix
  if [ -z "$core" ]; then
    echo "  codex CLI   : present (version unknown)"
  else
    lowest="$(printf '%s\n%s\n' "$core" "$REQUIRED_CODEX" | sort -V | head -1)"
    # Below if the numeric core is lower, OR it is a prerelease OF the minimum
    # (e.g. 0.137.0-rc.1 < the released 0.137.0).
    if { [ "$lowest" = "$core" ] && [ "$core" != "$REQUIRED_CODEX" ]; } \
       || { [ "$core" = "$REQUIRED_CODEX" ] && [ "$raw" != "$core" ]; }; then
      echo "  codex CLI   : $raw  WARNING below required >= $REQUIRED_CODEX"
    else
      echo "  codex CLI   : $raw  (>= $REQUIRED_CODEX OK)"
    fi
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
  # armed_at age (0.8+): the hook auto-expires gates armed more than 14 days
  # ago. A file without armed_at (≤0.7) is TTL-exempt — nothing to show.
  if has_field "$f" armed_at; then
    aa="$(field "$f" armed_at)"
    now="$(date +%s 2>/dev/null)"
    case "$aa" in
      ''|*[!0-9]*) echo "      WARNING armed_at is not a numeric epoch ('$aa') — the hook skips TTL for this gate." ;;
      *)
        if [ -n "$now" ] && [ "$aa" -le "$now" ]; then
          age_days=$(( (now - aa) / 86400 ))
          if [ $(( now - aa )) -gt 1209600 ]; then
            echo "      WARNING armed ${age_days}d ago — past the 14-day TTL; will auto-expire on the next gated turn."
          else
            echo "      armed ${age_days}d ago (auto-expires 14d after arming)"
          fi
        else
          echo "      WARNING armed_at is in the future — the hook skips TTL for this gate."
        fi
        ;;
    esac
  fi
  if [ -n "$at" ] && [ ! -f "$STATE_DIR/$at.log" ] && [ ! -f "$STATE_DIR/$at.id" ]; then
    echo "      WARNING target thread '$at' has no log/id on disk — the gate cannot find it. Did you run /$base with a different --thread name?"
  fi
  [ -n "$at" ] && echo "      last verdict on $at (whole log — the gate releases only on an APPROVE made AFTER arming): $(last_verdict "$at")"
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
  # Only review/plan threads run a verdict contract; ask/debate/plain threads do
  # not, so don't mislabel a coincidental APPROVE-shaped last line as a verdict.
  case "$n" in review*|plan*) v="$(last_verdict "$n")" ;; *) v="n/a" ;; esac
  printf '  %-30s rounds=%-3s size=%-8s last=%-16s verdict=%s\n' \
    "$n" "$r" "${sz:-0}" "$(_mtime "$idf")" "$v"
done
[ "$any" = 0 ] && echo "  (none)"
# Explicit success — the final test above is false when threads exist, which
# would otherwise make this read-only command exit non-zero on the normal path.
exit 0
