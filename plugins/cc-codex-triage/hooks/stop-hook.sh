#!/usr/bin/env bash
# cc-codex-triage — Stop hook for /autoreview and /autoplan self-verification.
#
# FAST and fail-open: no Codex call happens inside this hook. It only decides
# whether Claude may finish the turn, or must first run /review (or /plan) on
# its own changes. The actual review runs through the normal commands/driver.
#
# The unit of work is a CYCLE, not an arming: it opens when the code differs
# from the last state this gate released and closes on a verdict earned inside
# it. Each release re-baselines the approved fingerprint, the verdict window and
# the round counter together (see rebaseline_cycle). The previous "dirty tree +
# last verdict" model had two reproducible holes — committing the fixes went
# quiet while the verdict was still REQUEST_CHANGES, and the first APPROVE
# released every later turn for the rest of the arming.
#
# Runaway protection (hard, independent of Claude Code internals):
#   1. blocks counter vs cap, per cycle — the hard terminator. Counters are
#      numeric-validated; ANY malformed value fails OPEN. Only a real release
#      refills the budget, so a cycle that never earns one stops at `cap`.
#   2. Success gates: autoreview releases on an APPROVE verdict appended to the
#      thread log after the cycle's byte-offset cut; autoplan releases once the
#      thread log changed size within the cycle (a dispatch always appends).
#   3. Scoping: the armed branch must match the current branch, and the code
#      fingerprint for that gate's file class must differ from the released
#      baseline.
#   4. TTL: an armed file whose armed_at epoch is older than 14 days is
#      removed by a pre-pass over BOTH files before either gate runs.
#      Missing/malformed/future armed_at skips TTL for that file (fail-open —
#      ≤0.7 armed files have no armed_at and keep working).
#
# stop_hook_active is deliberately NOT an unconditional allow: honoring it
# would cap the gate at one block per user turn and silently break the
# advertised "until APPROVE or cap" contract. The numeric cap bounds cost
# instead (at most `cap` blocks per cycle).
#
# Armed state (written by /autoreview, /autoplan commands; released_fp and the
# advanced log offset are written by THIS hook):
#   .claude/codex-threads/autoreview.armed
#   .claude/codex-threads/autoplan.armed
#   KEY=VALUE lines: branch, thread, lens, cap, blocks, log_bytes_at_arming,
#   armed_at (0.8+, drives the TTL), fp_at_arming (0.9+), released_fp (0.9+,
#   hook-written).
#   log_bytes_at_arming is REQUIRED (missing = pre-0.5 arming = fail open). It
#   is the cycle's verdict cut, advanced on every release so one verdict cannot
#   release two cycles. fp_at_arming / released_fp are OPTIONAL: with neither,
#   the file is a pre-0.9 arming and keeps the dirty-tree test until its first
#   release, then follows the cycle model — so an upgrade never changes a gate
#   mid-cycle, and an old gate still picks up the fix.
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
# Plan-doc locations, configurable via CC_CODEX_PLAN_PATHS (space-separated
# pathspecs). Defined ONCE: the dirt predicate and the fingerprint call must
# agree, and they were two independent copies of the same default.
PLAN_PATHS="${CC_CODEX_PLAN_PATHS:-docs/plans docs/PLANS}"
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
# Numeric AND small enough for shell arithmetic. A cap of 10^20 is not a cap,
# and an offset that long makes `[` and `$(( ))` error out downstream — which
# would block on broken state instead of failing open. 9 digits is far above
# any real cap, block count or log size.
is_bounded_num() { is_num "$1" && [[ "${#1}" -le 9 ]]; }
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

# Rewrite an armed file atomically. Every writer used a shared, predictable
# "$f.tmp": two concurrent hooks then had one truncating the temp file while the
# other's `grep -v` was still reading it, and the survivor kept only its own
# appended line. Reproduced with 20 parallel hooks — the armed file came out as
# the single line `blocks=1`, with branch/thread/cap/fp_at_arming GONE. That is
# not a lost update, it is a silently and permanently disarmed gate.
#
# A per-writer temp plus rename makes each rewrite all-or-nothing. Concurrent
# writers can still lose an increment (last rename wins), which only makes the
# cap arrive later — it cannot corrupt the file or bypass the cap.
# Serialize the whole read-validate-rewrite. Atomic rename already stopped the
# file being CORRUPTED, but concurrent hooks still lost increments (last rename
# wins), so twenty parallel blocks counted as one and the cap arrived twenty
# times later than it should.
#
# mkdir is atomic on POSIX — the same primitive the driver's lease uses. The
# hook must stay fast and fail OPEN, so this never waits long and never blocks
# on a lock it cannot get: a handful of short retries, then give up and let the
# caller proceed unserialized (the rename keeps that safe, just lossy).
# A lock older than 30s is stale by construction — nothing here holds it for
# more than a few file operations.
armed_lock() { # $1=armed file → 0 if held
  local d="$1.lock" i=0 age now
  while [ "$i" -lt 25 ]; do
    if mkdir "$d" 2>/dev/null; then return 0; fi
    now="$(date +%s 2>/dev/null)" || return 1
    age="$(_lock_age "$d" "$now")"
    if [ -n "$age" ] && [ "$age" -gt 30 ]; then rm -rf "$d" 2>/dev/null; continue; fi
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i+1))
  done
  return 1
}
armed_unlock() { rm -rf "$1.lock" 2>/dev/null; }
_lock_age() { # $1=lock dir $2=now — GNU first, per the stat-probe rule above
  local m
  m="$(stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null)" || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$(( $2 - m ))"
}

armed_rewrite() { # $1=armed file; body on stdin
  local f="$1" tmp
  tmp="$(mktemp "$f.XXXXXX" 2>/dev/null)" || return 1
  if cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

bump_blocks() { # $1=file $2=current — rewrite with blocks incremented.
  # Returns non-zero if the increment could NOT be persisted (e.g. read-only
  # state dir). The caller must then fail OPEN: blocking without a persisted
  # counter would bypass the cap into unlimited blocking.
  # Re-read the counter INSIDE the lock: the value the caller validated may be
  # stale by now, and incrementing a stale value is exactly the lost update.
  local f="$1" b cur locked=false
  armed_lock "$f" && locked=true
  cur="$(raw_field "$f" blocks)"
  is_bounded_num "$cur" || cur="$2"
  b=$(( cur + 1 ))
  # stderr is silenced on the write itself: a read-only state dir otherwise
  # prints a raw "…armed.tmp: Permission denied" next to the tidy explanation
  # below, and the raw one is the confusing half.
  { grep -v '^blocks=' "$f" 2>/dev/null
    echo "blocks=$b"
  } | armed_rewrite "$f" || { $locked && armed_unlock "$f"; return 1; }
  $locked && armed_unlock "$f"
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
  # Word-splitting PLAN_PATHS into separate pathspecs is intentional.
  local paths="$PLAN_PATHS"
  # `set -f` (in a subshell) disables shell globbing so the pathspecs reach git
  # unexpanded — git does its own pathspec matching.
  # shellcheck disable=SC2086
  ( set -f; git status --porcelain -uall -- $paths 2>/dev/null | grep -q . )
}

code_fingerprint() { # $1 = optional pathspec list (autoplan); empty = whole tree
  # The ONE canonical implementation, shared with the arming commands: a copy
  # that drifted by a pathspec would make every gate read as permanently dirty.
  local fpsh="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/gate-fingerprint.sh}"
  [[ -n "$fpsh" && -f "$fpsh" ]] || {
    echo "cc-codex-triage: gate-fingerprint.sh not found next to the hook — the gate falls back to the dirty-tree test for this turn." >&2
    return 0
  }
  local fp
  # shellcheck disable=SC2086
  fp="$( set -f; bash "$fpsh" ${1:-} 2>/dev/null )"
  # Empty means it ran and could not compute. The gate then degrades to the
  # dirty-tree test — weaker, so it must not be silent.
  [[ -n "$fp" ]] || echo "cc-codex-triage: the code fingerprint could not be computed (unreadable file? git error?) — the gate falls back to the dirty-tree test for this turn." >&2
  printf '%s' "$fp"
}

# Mirrored in scripts/lib.sh for /status and /cleanup. The copy is deliberate —
# lib.sh's header records that this hook does not source it, so it stays
# dependency-free. Change both together.
gate_baseline() { # $1=armed file — the code state this gate last RELEASED,
  # else the state captured at arming. Empty when neither is recorded, which
  # means a pre-0.9 armed file: the caller then keeps the old dirty-only test
  # so upgrading Claude Code mid-task never silently changes a live gate.
  local v
  v="$(raw_field "$1" released_fp)"
  [[ -n "$v" ]] || v="$(raw_field "$1" fp_at_arming)"
  printf '%s' "$v"
}

has_unreviewed_work() { # $1=baseline fp  $2=current fp  $3=legacy dirt predicate
  # No baseline (pre-0.9 file) or no current fingerprint (script missing, git
  # failure) both fall back to the dirty-tree predicate. The second case used to
  # disable the gate while the stderr note claimed a fallback; a weakened gate
  # beats none, and the note is now true.
  { [[ -n "$1" && -n "$2" ]]; } || { "$3"; return; }
  [[ "$1" != "$2" ]]
}

reviewed_fingerprint() { # $1=thread $2=fallback — what Codex actually looked at.
  # The driver snapshots the state it dispatched against, in
  # <thread>.dispatch-fp. Releasing against that rather than the worktree at
  # turn-end keeps code written after the verdict from being stamped approved.
  # A stale file describes an EARLIER state, so the next turn blocks — safe.
  #
  # $3="plan" selects the PLAN-SCOPED snapshot the driver writes for the thread
  # the autoplan gate watches. Without it the whole-tree hash is compared against
  # a pathspec hash, which can never be equal — so every autoplan release
  # immediately re-blocked, to the cap. The tests missed it because they wrote no
  # sidecar at all and so only ever exercised the fallback.
  #
  # Preference order, strongest first:
  #   1. the fingerprint stamped into the log record that CONTAINED the selected
  #      verdict — the only source that is guaranteed to describe the state that
  #      verdict judged (for the plan gate, the LATEST record instead: that gate
  #      releases on log growth, so the releasing dispatch is the last one);
  #   2. the sidecar, i.e. the LATEST successful dispatch on this thread. Right
  #      whenever that dispatch is the one that produced the verdict, which is
  #      the ordinary case;
  #   3. the caller's Stop-time fingerprint.
  # A record predating `fp=` falls through to 2 — sound while it is the last
  # record, and an existing thread keeps working. Once a LATER dispatch has
  # overwritten the sidecar, 2 describes that dispatch rather than the verdict,
  # and no source can pair them: the parser answers AMBIGUOUS and this returns it
  # verbatim so the caller refuses to release.
  local v f="$STATE_DIR/$1.dispatch-fp" flag="--fp"
  # The plan gate releases on log GROWTH, not on a verdict, so the dispatch that
  # releases it is the LATEST one. Asking for the verdict's record here released
  # the state an older APPROVE covered and re-blocked the current one.
  if [[ "${3:-}" == "plan" ]]; then f="$STATE_DIR/$1.dispatch-fp-plan"; flag="--fp-plan-latest"; fi
  v="$(bash "$VERDICT_SH" "$STATE_DIR/$1.log" "${4:-0}" "$flag" 2>/dev/null | tr -d '[:space:]')"
  # A markerless verdict with a later record behind it: the sidecar now belongs
  # to that later dispatch, so nothing here can say what the verdict judged.
  # Passed through verbatim — substituting the caller's fallback would release
  # the newest state on the strength of an older verdict, which is the very hole
  # the log markers exist to close.
  [[ "$v" == "AMBIGUOUS" ]] && { printf 'AMBIGUOUS'; return 0; }
  [[ -n "$v" ]] || v="$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')"
  [[ "$v" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || v="$2"   # SHA-1 or SHA-256 object id
  printf '%s' "$v"
}

consume_idle_verdicts() { # $1=armed file $2=current fp $3=thread
  # With no cycle open, a verdict appended since the last cut answers nothing —
  # and left in place it BANKS: the next cycle finds that APPROVE already past
  # the offset and releases without a review. /autoreview's own arming produces
  # exactly that (it writes fp_at_arming, then reviews existing work), which
  # shipped the first change after arming ungated.
  #
  # 0.9 files only — a pre-0.9 file keeps 0.8 semantics until its first release.
  # Writes only when the log grew, so an idle turn costs one wc -c.
  # OFFSET ONLY — never rebaseline_cycle. That resets blocks=0, so reverting to
  # the released state, letting the idle pass consume, then reapplying the
  # change bought a full cap again, repeatably: the cap stopped bounding cost.
  # Only an earned release refills the budget.
  #
  # Runs for pre-0.9 files too. Their fingerprint fields stay untouched (so the
  # dirty-tree predicate still governs them, as documented), but an APPROVE that
  # arrived while clean would otherwise sit past the cut and release the next
  # dirty state — the banking hole, in the compatibility path.
  local f="$1" t="$3" now off
  has_field "$f" log_bytes_at_arming || return 0
  off="$(raw_field "$f" log_bytes_at_arming)"
  is_bounded_num "$off" || return 0
  now="$(log_size "$t")"
  [[ "$now" -ne "$off" ]] || return 0
  { grep -v -e '^log_bytes_at_arming=' "$f" 2>/dev/null
    echo "log_bytes_at_arming=$now"
  } | armed_rewrite "$f" || true
  return 0
}

rebaseline_cycle() { # $1=armed file $2=fingerprint $3=thread — start a new cycle.
  # All three move together or the next cycle is evaluated on stale state:
  #   released_fp          what was approved, so a later edit re-arms the gate;
  #   log_bytes_at_arming  advanced, so this cycle's verdict cannot release the
  #                        next one;
  #   blocks=0             a fresh budget — refilled only by a real release, so
  #                        a cycle that never earns one still stops at `cap`.
  # Diagnoses its own failure (the two causes need different advice) and returns
  # non-zero; the caller releases anyway — a persisted marker is not worth
  # withholding an earned APPROVE over.
  local f="$1" fp="$2" size
  if [[ -z "$fp" ]]; then
    echo "cc-codex-triage: released, but the code fingerprint is unavailable so the release could not be recorded — the next turn re-evaluates from the previous baseline." >&2
    return 1
  fi
  size="$(log_size "$3")"
  if ! { grep -v -e '^released_fp=' -e '^blocks=' -e '^log_bytes_at_arming=' "$f" 2>/dev/null
         echo "released_fp=$fp"
         echo "log_bytes_at_arming=$size"
         echo "blocks=0"
       } | armed_rewrite "$f"; then
    echo "cc-codex-triage: released, but could not write $f (state dir not writable?) — the next turn may re-block. Re-arm to continue." >&2
    return 1
  fi
}

# Resolved once. A missing parser means the gate cannot evaluate at all, and it
# must not guess in EITHER direction: a faked APPROVE would record a
# released_fp and mark unreviewed code as approved, while treating it as "no
# verdict" would block every cycle to its cap on a broken install. The gate is
# skipped instead, loudly, touching no state.
VERDICT_SH="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/last-verdict.sh}"
VERDICT_SH_OK=1
if [[ -z "$VERDICT_SH" || ! -f "$VERDICT_SH" ]]; then
  echo "cc-codex-triage: last-verdict.sh not found next to the hook — cannot read thread verdicts, skipping the autoreview gate for this turn." >&2
  VERDICT_SH_OK=0
fi

# ── Gate TTL pre-pass ───────────────────────────────────────────────────────
# An armed gate older than 14 days is stale — a month-old gate re-firing on a
# reused branch name is the audited hazard. This runs over BOTH armed files
# BEFORE either gate evaluates branch/dirt: the gates run sequentially and
# allow/emit_block exit the whole hook, so inline expiry inside a gate would
# suppress or orphan the other gate. The pre-pass itself never exits — gate
# evaluation proceeds on whatever survived.
# Fail-open: missing/malformed/future armed_at (including every ≤0.7 armed
# file, which has no armed_at) skips TTL for that file. An expired file that
# cannot be removed is treated as absent for the remainder of THIS run only —
# never block on an unremovable stale gate.
GATE_TTL=1209600   # 14 days, in seconds
epoch_date() { # $1=epoch → ISO day. GNU FIRST: GNU's `date -r` takes a FILE, so
  # `date -r <epoch>` succeeds against a same-named file and reports its mtime
  # instead of the epoch — the same failure shape as the stat probes.
  date -d "@$1" '+%Y-%m-%d' 2>/dev/null || date -r "$1" '+%Y-%m-%d' 2>/dev/null || printf 'epoch %s' "$1"
}
AR_TTL_DEAD=0; AP_TTL_DEAD=0
NOW="$(date +%s 2>/dev/null || true)"
if is_num "${NOW:-}"; then
  for kind in autoreview autoplan; do
    f="$STATE_DIR/$kind.armed"
    [[ -f "$f" ]] || continue
    armed_at="$(raw_field "$f" armed_at)"
    is_num "$armed_at" || continue            # missing/malformed → TTL skipped
    [[ "${#armed_at}" -le 12 ]] || continue   # absurd length would overflow bash arithmetic
    [[ "$armed_at" -le "$NOW" ]] || continue  # future timestamp → TTL skipped
    [[ $(( NOW - armed_at )) -gt "$GATE_TTL" ]] || continue
    if rm -f "$f" 2>/dev/null && [[ ! -e "$f" ]]; then
      echo "$kind gate expired after 14 days (armed $(epoch_date "$armed_at")) — removed; re-arm with /$kind on." >&2
    else
      echo "$kind gate expired after 14 days (armed $(epoch_date "$armed_at")) but could not be removed (state dir not writable?) — ignoring it for this turn; re-arm with /$kind on." >&2
      case "$kind" in autoreview) AR_TTL_DEAD=1 ;; autoplan) AP_TTL_DEAD=1 ;; esac
    fi
  done
fi

# ── gate scope ──────────────────────────────────────────────────────────────
# Both gates are resolved BEFORE either is evaluated, because emit_block and
# allow exit the whole hook: a block on autoreview used to skip autoplan
# entirely, including its idle-verdict consumption, so plan-thread growth
# during a blocked turn banked and released the next plan cycle for free.
# The fingerprint runs only after the branch check — it walks the worktree, and
# an armed gate on another branch should cost nothing.
AR="$STATE_DIR/autoreview.armed"
AP="$STATE_DIR/autoplan.armed"
AR_LIVE=0; AP_LIVE=0; ar_fp=""; ap_fp=""; ar_thread=""; ap_thread=""

if [[ -f "$AR" && "$AR_TTL_DEAD" -eq 0 && "$VERDICT_SH_OK" -eq 1 \
      && "$(read_field "$AR" branch "")" == "$BRANCH" ]]; then
  AR_LIVE=1
  ar_thread="$(read_field "$AR" thread "review-$BRANCH_SLUG")"
  is_thread "$ar_thread" || ar_thread="review-$BRANCH_SLUG"
  ar_fp="$(code_fingerprint)"
fi
if [[ -f "$AP" && "$AP_TTL_DEAD" -eq 0 && "$(read_field "$AP" branch "")" == "$BRANCH" ]]; then
  AP_LIVE=1
  ap_thread="$(read_field "$AP" thread "plan-$BRANCH_SLUG")"
  is_thread "$ap_thread" || ap_thread="plan-$BRANCH_SLUG"
  ap_fp="$(code_fingerprint "$PLAN_PATHS")"
fi

# Idle-verdict pre-pass over BOTH gates, for the reason above.
if [[ "$AR_LIVE" -eq 1 ]] && ! has_unreviewed_work "$(gate_baseline "$AR")" "$ar_fp" dirty_code; then
  consume_idle_verdicts "$AR" "$ar_fp" "$ar_thread"
fi
if [[ "$AP_LIVE" -eq 1 ]] && ! has_unreviewed_work "$(gate_baseline "$AP")" "$ap_fp" dirty_plans; then
  consume_idle_verdicts "$AP" "$ap_fp" "$ap_thread"
fi

# ── /autoreview ─────────────────────────────────────────────────────────────
if [[ "$AR_LIVE" -eq 1 ]]; then
  thread="$ar_thread"
    if has_unreviewed_work "$(gate_baseline "$AR")" "$ar_fp" dirty_code; then
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
      elif ! is_bounded_num "$cap" || ! is_bounded_num "$blocks" || ! is_bounded_num "$log_off"; then
        echo "autoreview: malformed counters in $AR — failing open. Re-arm with /autoreview on." >&2
      else
        # The ONE canonical parser, which /status also calls — two copies
        # disagreeing would mean /status reporting an APPROVE while the gate
        # keeps blocking on the same log. Availability is settled at VERDICT_SH.
        verdict="$(bash "$VERDICT_SH" "$STATE_DIR/$thread.log" "$log_off" 2>/dev/null)"
        # The offset cut makes the verdict self-sufficient: an APPROVE can only
        # come from log content appended after arming, which itself proves a
        # post-arming round ran. No .rounds-based second check — that counter is
        # reset by /thread-new, so it can both fake a run (reset alone changes
        # it) and mask one (reset + one run collides with the snapshot).
        # An APPROVE whose record carries no fingerprint AND has a later dispatch
        # behind it cannot be tied to any state: the sidecar describes that later
        # dispatch. Releasing anyway would stamp the newest bytes approved on the
        # strength of an older verdict. Demote it to no-verdict so the gate keeps
        # blocking — the next dispatch stamps its own record and settles it.
        if [[ "$verdict" == "APPROVE" ]]; then
          ar_released="$(reviewed_fingerprint "$thread" "$ar_fp" "" "$log_off")"
          if [[ "$ar_released" == "AMBIGUOUS" ]]; then
            echo "autoreview: the APPROVE on thread $thread predates fingerprint records and a later dispatch has replaced the snapshot, so what it approved cannot be established — not releasing. Re-review to settle it." >&2
            verdict="UNATTRIBUTABLE_APPROVE"
          fi
        fi
        if [[ "$verdict" == "APPROVE" ]]; then
          # APPROVE earned this cycle — release, and record WHAT it approved.
          # Without the record, this one verdict would keep releasing every
          # later turn no matter how much new unreviewed code was written.
          rebaseline_cycle "$AR" "$ar_released" "$thread" || true   # diagnoses itself
          # The approval covers the state Codex saw. If the worktree has moved
          # past it — code written after the verdict arrived, in this same turn
          # — the next cycle is open ALREADY. Open it now rather than letting
          # the turn end and catching it only if there happens to be another.
          if [[ -n "$ar_released" && -n "$ar_fp" && "$ar_released" != "$ar_fp" ]]; then
            nblocks="$(raw_field "$AR" blocks)"; is_bounded_num "$nblocks" || nblocks=0
            if [[ "$nblocks" -lt "$cap" ]] && n="$(bump_blocks "$AR" "$nblocks")"; then
              emit_block "autoreview armed: the APPROVE covers the state that was reviewed, but the code changed after it — review the new changes. Read $CMD_DIR/review.md and follow its steps with --once --thread $thread --lens $lens. Round $n/$cap. Disarm with the autoreview command (off)."
            fi
          fi
        elif [[ "$blocks" -ge "$cap" ]]; then
          echo "autoreview: round cap ($cap) reached without APPROVE on thread $thread — letting the turn finish. See the thread log for open findings; disarm with /autoreview off or re-arm to continue." >&2
        elif n="$(bump_blocks "$AR" "$blocks")"; then
          emit_block "autoreview armed: there are unverified code changes. Read $CMD_DIR/review.md and follow its steps to review your changes with --once --thread $thread --lens $lens (--once so this gate block is a SINGLE dispatch — the cap counts blocks, and a default loop here would multiply cost). Validate each finding against the code before applying it, and fix the neighborhood of valid ones, per skill codex-triage. Then finish the turn. Round $n/$cap. Disarm with the autoreview command (off)."
        else
          echo "autoreview: could not persist the blocks counter (state dir not writable?) — failing open; an unpersisted counter would bypass the cap into unlimited blocking." >&2
        fi
      fi
    fi
fi

# ── /autoplan ───────────────────────────────────────────────────────────────
if [[ "$AP_LIVE" -eq 1 ]]; then
  thread="$ap_thread"
    if has_unreviewed_work "$(gate_baseline "$AP")" "$ap_fp" dirty_plans; then
      lens="$(read_field "$AP" lens stress-test)"
      is_plan_lens "$lens" || lens=stress-test
      cap="$(raw_field "$AP" cap)"
      blocks="$(raw_field "$AP" blocks)"
      log_off="$(raw_field "$AP" log_bytes_at_arming)"
      log_now="$(log_size "$thread")"
      if ! has_field "$AP" log_bytes_at_arming; then
        echo "autoplan: armed file has no log_bytes_at_arming (pre-0.5 arming) — failing open. Re-arm with /autoplan on." >&2
      elif ! is_bounded_num "$cap" || ! is_bounded_num "$blocks" || ! is_bounded_num "$log_off"; then
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
        # At least one dispatch on the plan thread this cycle — release, and
        # record the plan state it covered plus the new log baseline, so the
        # NEXT plan edit needs its OWN dispatch rather than coasting on this one.
        # The PLAN-SCOPED snapshot the driver takes for this thread — not the
        # whole-tree one, which could never compare equal to a pathspec
        # fingerprint and would block every turn to the cap. Falls back to the
        # Stop-time fingerprint when no snapshot exists (older state, or a
        # thread the driver did not recognise as the armed plan thread).
        ap_released="$(reviewed_fingerprint "$thread" "$ap_fp" plan "$log_off")"
        rebaseline_cycle "$AP" "$ap_released" "$thread" || true   # diagnoses itself
        # Plan edits made AFTER the releasing dispatch are not covered by it, so
        # open the next cycle now rather than ending the turn on them.
        if [[ -n "$ap_released" && -n "$ap_fp" && "$ap_released" != "$ap_fp" ]]; then
          nblocks="$(raw_field "$AP" blocks)"; is_bounded_num "$nblocks" || nblocks=0
          if [[ "$nblocks" -lt "$cap" ]] && n="$(bump_blocks "$AP" "$nblocks")"; then
            emit_block "autoplan armed: the plan documents changed after the dispatch that released the last cycle, so the current plan has not been stress-tested. Read $CMD_DIR/plan.md and follow its steps with --once --thread $thread --lens $lens. Round $n/$cap. Disarm with the autoplan command (off)."
          fi
        fi
      elif [[ "$blocks" -ge "$cap" ]]; then
        echo "autoplan: round cap ($cap) reached without a post-arming dispatch on thread $thread — letting the turn finish. Disarm with /autoplan off or re-arm." >&2
      elif n="$(bump_blocks "$AP" "$blocks")"; then
        emit_block "autoplan armed: plan documents changed but have not been stress-tested. Read $CMD_DIR/plan.md and follow its steps to stress-test the updated plan with --once --thread $thread --lens $lens (--once so this gate block is a SINGLE dispatch — the cap counts blocks). Address blocking objections, then finish the turn. Round $n/$cap. Disarm with the autoplan command (off)."
      else
        echo "autoplan: could not persist the blocks counter (state dir not writable?) — failing open; an unpersisted counter would bypass the cap into unlimited blocking." >&2
      fi
    fi
fi

allow
