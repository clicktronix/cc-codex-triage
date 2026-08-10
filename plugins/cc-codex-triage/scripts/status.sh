#!/usr/bin/env bash
# cc-codex-triage — /status: one-screen view of thread + gate state.
#
# READ-ONLY: never writes or mutates any state (safe to run any time). It
# surfaces exactly the things that used to require hand-reading .armed/.rounds/
# .log + git: current branch, dirty tree, armed gates (with stale-branch /
# pre-0.5 / missing-target warnings), last verdict per thread, required-review
# gate state, gitignore status, and the Codex CLI version vs the required
# minimum.

set -u

# Shared helpers (field / has_field / _mtime). Resolve the script's own dir
# BEFORE the cd below so the source path stays valid regardless of caller cwd.
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SELF_DIR/lib.sh"

# Anchor to the resolved repo before resolving its common Git state. Read-only
# outside a repo: no arbitrary cwd-local directory can be mistaken for state.
if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "Not inside a git repository — no thread state to report."
  exit 0
fi
cd "$ROOT" || { echo "Not inside a git repository — no thread state to report."; exit 0; }
STATE_DIR="$(bash "$SELF_DIR/state-dir.sh" --read-only)" || exit $?
GATE_DIR="$(bash "$SELF_DIR/gate-dir.sh" --read-only)" || exit $?
REQUIRED_CODEX="0.137.0"   # keep in sync with the minimum stated in README.md (Prerequisites)

# Last verdict from a thread log — whole log, no offset, informational. Same
# parser the Stop hook uses; a second one here would eventually report an
# APPROVE the gate refuses. Prints '-' when none.
VERDICT_SH="$(cd "$(dirname "$0")" && pwd)/last-verdict.sh"
FP_SH="$(cd "$(dirname "$0")" && pwd)/gate-fingerprint.sh"
last_verdict() {
  local v
  v="$(bash "$VERDICT_SH" "$STATE_DIR/$1.log" 0 2>/dev/null)"
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

# Same fallback the hook keeps: with the script missing (a partial install —
# the case the hook explicitly guards), an empty list becomes `git status -- `,
# i.e. NO pathspec, and /status reports every change in the tree as a plan-doc
# change. Read by the cycle-state check below too.
plan_paths="$(bash "$FP_SH" --plan-paths 2>/dev/null)"
[ -n "$plan_paths" ] || plan_paths="${CC_CODEX_PLAN_PATHS:-docs/plans docs/PLANS}"
if $IN_GIT; then
  code_changes=$(git status --porcelain -uall 2>/dev/null | grep -vF '.claude/codex-threads/' | grep -c . | tr -d ' ')
  # Word-split the pathspecs (intentional) but disable shell globbing so they
  # reach git unexpanded — git does its own pathspec matching. shellcheck disable=SC2086
  plan_changes=$( set -f; git status --porcelain -uall -- $plan_paths 2>/dev/null | grep -c . | tr -d ' ' )
  echo "  working tree: ${code_changes:-0} code change(s), ${plan_changes:-0} plan-doc change(s)"
  echo "                (a dirty tree is NOT what the gates compare — see 'cycle' below)"
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

echo "  state dir   : $STATE_DIR (shared across worktrees)"
echo "  gate dir    : $GATE_DIR (current worktree only)"

if [ ! -d "$STATE_DIR" ] && [ ! -d "$GATE_DIR" ]; then
  echo
  echo "No threads or gates in this repo yet."
  exit 0
fi

# ── Armed gates ─────────────────────────────────────────────────────────────
echo
echo "Armed gates:"
shown=0
for kind in autoreview autoplan; do
  f="$GATE_DIR/$kind.armed"
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
    # Mirror the hook's canonical armed_at validation (stop-hook.sh: is_num +
    # 12-digit length cap) BEFORE any arithmetic: a leading-zero value like
    # "08" is bash's invalid-octal trap and an absurd length would overflow —
    # both must warn, never crash this read-only view.
    case "$aa" in
      ''|*[!0-9]*|0?*) echo "      WARNING armed_at is not a numeric epoch ('$aa') — the hook skips TTL for this gate." ;;
      *)
        if [ "${#aa}" -gt 12 ]; then
          echo "      WARNING armed_at is implausibly long ('$aa') — the hook skips TTL for this gate."
        elif [ -n "$now" ] && [ "$aa" -le "$now" ]; then
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
  # Cycle state: a clean tree is not what the gate compares against.
  if [ -n "$(gate_baseline "$f")" ]; then
    case "$kind" in
      autoplan) fp_now="$(bash "$FP_SH" --read-only --plan 2>/dev/null)" ;;
      *)        fp_now="$(bash "$FP_SH" --read-only 2>/dev/null)" ;;
    esac
    fp_base="$(gate_baseline "$f")"
    if [ -z "$fp_now" ]; then
      echo "      cycle: UNKNOWN — the code fingerprint could not be computed; the gate falls back to its dirty-tree test"
    elif [ "$fp_now" = "$fp_base" ]; then
      echo "      cycle: at baseline — nothing to review, the gate will not fire"
    else
      echo "      cycle: OPEN — the code differs from the last released state; this gate blocks until a verdict inside this cycle"
    fi
  else
    echo "      cycle: n/a — armed before 0.9, still using the dirty-tree test until its first release"
  fi
  [ -n "$at" ] && echo "      last verdict on $at (whole log — the gate releases only on a verdict made INSIDE the current cycle): $(last_verdict "$at")"
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

# ── Required review gates ───────────────────────────────────────────────────
# The verdict column above comes from the tolerant informational parser, which
# accepts `## APPROVE` and `**APPROVE**`. The required gate accepts the bare
# token only. Printing the log verdict alone would report an approval the gate
# refused — and a PENDING claim or a CAP_REACHED hard stop would be invisible
# in the one screen that exists to make state readable.
echo
echo "Required review gates:"
req=0
for sf in "$STATE_DIR"/*.review-state; do
  [ -f "$sf" ] || continue
  req=1
  n="$(basename "$sf" .review-state)"
  st="$(field "$sf" status)"; ge="$(field "$sf" gate_eligible)"; vd="$(field "$sf" verdict)"
  printf '  %-30s status=%-22s gate_eligible=%-5s verdict=%s\n' \
    "$n" "${st:-?}" "${ge:-?}" "${vd:--}"
  case "$st" in
    PENDING)
      exp="$(field "$sf" claim_expires_at)"; now="$(date +%s 2>/dev/null)"
      case "$exp" in
        ''|*[!0-9]*|0?*) echo "      claim has no usable expiry — /thread-new $n clears it." ;;
        *)
          if [ -z "$now" ] || [ "${#exp}" -gt 12 ]; then
            echo "      claim expiry cannot be evaluated here — /thread-new $n clears it."
          elif [ "$exp" -le "$now" ]; then
            echo "      claim EXPIRED — record the finished dispatch, or /thread-new $n to release it."
          else
            echo "      claim live for $(( (exp - now) / 60 ))m — a round is in flight; do not begin another."
          fi
          ;;
      esac
      ;;
    CAP_REACHED|DIVERGED)
      echo "      HARD STOP — never an approval. Decide with the user, then /thread-new $n to start a fresh required lifecycle."
      ;;
    APPROVED)
      # Deliberately not re-deciding coverage here: `check` takes the review
      # mutex, and this command is read-only. Naming the one authority beats
      # growing a second staleness test that could disagree with it.
      echo "      recorded for head=$(field "$sf" head) — authoritative re-check: review-state.sh check $n"
      ;;
  esac
  # Deliberately a second test on $st rather than an arm of the case above: this
  # applies to EVERY status except APPROVED, including the PENDING and
  # CAP_REACHED arms already handled, and a `*)` arm would silently stop warning
  # exactly where a decorated verdict burned the cap.
  if [ "$st" != "APPROVED" ] && [ "$(last_verdict "$n")" = "APPROVE" ]; then
    echo "      WARNING the log's last verdict reads APPROVE but the required gate did not accept it (status=${st:-?})."
    # The recovery differs by status, and a blanket "re-run the round" contradicts the hard stop
    # printed two lines above — the one case where re-running is exactly what must not happen.
    case "$st" in
      CAP_REACHED|DIVERGED)
        echo "              A decorated verdict is one way the budget went: the gate takes the bare token"
        echo "              on its own final line. Recovery is the hard stop above, not another round."
        ;;
      STALE)
        echo "              STALE covers every way the round could not be attributed to this"
        echo "              candidate — moved HEAD or tree, changed fingerprint, wrong prompt scope,"
        echo "              or a round counter that did not advance. Recorded reason:"
        echo "              $(field "$sf" reason). Read that before changing the candidate."
        ;;
      *)
        echo "              The gate needs the verdict alone on its own final line, undecorated. Re-run the round."
        ;;
    esac
  fi
done
[ "$req" = 0 ] && echo "  (none)"
# Explicit success — the final test above is false when threads exist, which
# would otherwise make this read-only command exit non-zero on the normal path.
exit 0
