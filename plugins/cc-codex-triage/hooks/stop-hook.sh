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
# the round counter together (see rebaseline_cycle).
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
#   log_bytes_at_arming is REQUIRED (missing = pre-0.5 arming = fail open) and
#   is the cycle's verdict cut, advanced on every release so one verdict cannot
#   release two cycles. With neither fp_at_arming nor released_fp the file is a
#   pre-0.9 arming: dirty-tree test until its first release, cycle model after.
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
# Numeric AND short enough for shell arithmetic: a 20-digit value makes `[` and
# `$(( ))` error out downstream, which would block on broken state instead of
# failing open. 9 digits is far above any real cap, count or log size.
is_bounded_num() { is_num "$1" && [[ "${#1}" -le 9 ]]; }
is_thread() { [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]; }
# Exact allowlists (not a character-class filter): the lens lands in the block
# reason as a --lens argument, and an unknown-but-printable value would route
# the model to an invalid invocation instead of the gate's default.
is_review_lens() { case "$1" in correctness|security|performance|architecture|ux|quick) return 0;; *) return 1;; esac; }
is_plan_lens() { case "$1" in stress-test|pre-mortem|devils-advocate|alternatives|adr) return 0;; *) return 1;; esac; }

# Field readers. Pure bash, no forks: `sed`+`head` per field cost more than
# everything else the gate does. HAS is set even for an empty value, so `key=`
# cannot silently become a default and bypass the caller's validation.
_field() { # $1=file $2=key -> VAL, HAS
  local line
  VAL=""; HAS=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$2="*) VAL="${line#*=}"; HAS=1; return 0 ;;
    esac
  done < "$1" 2>/dev/null
  return 0
}

read_field() { # $1=file $2=key $3=default — OPTIONAL fields with a safe fallback
  _field "$1" "$2"; printf '%s' "${VAL:-$3}"
}

raw_field() { # $1=file $2=key — REQUIRED fields: empty when missing or empty
  _field "$1" "$2"; printf '%s' "$VAL"
}

has_field() { _field "$1" "$2"; [ "$HAS" -eq 1 ]; } # $1=file $2=key

log_size() { # $1=thread — current byte size of the thread log, 0 if absent
  local s
  s="$(wc -c 2>/dev/null < "$STATE_DIR/$1.log")"
  s="${s//[[:space:]]/}"
  is_num "$s" || s=0
  printf '%s' "$s"
}

# All three armed-file writers rewrite the WHOLE file, so each serializes its
# read-validate-rewrite under a per-file mkdir mutex and re-reads inside it.
# Unserialized, concurrent hooks corrupted the file (a shared temp name left the
# survivor's single `blocks=1` line and nothing else) and lost increments (last
# rename wins), which unbounds the cap. Giving up means the caller does NOT
# write; each documents its own fallback.
#
# The token is per-process AND random: PIDs are recycled, and it must tell our
# lock from a replacement. A lock older than 30s is stale by construction —
# nothing here holds it for more than a few file operations.
ARMED_LOCK_TOKEN="$$.${RANDOM}${RANDOM}"

# stat flavour, resolved once: GNU-first is load-bearing (on GNU, `-f` means
# --file-system and SUCCEEDS), but probing it per call forks a guaranteed
# failure on every BSD box, and armed_lock can probe 25 times.
if stat -c '%Y' . >/dev/null 2>&1; then _STAT_FMT="-c%Y"; else _STAT_FMT="-f%m"; fi
_lock_mtime() { # $1=lock dir
  local m
  m="$(stat "$_STAT_FMT" "$1" 2>/dev/null)" || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$m"
}

armed_lock() { # $1=armed file → 0 if held
  local d="$1.lock" i=0 now m1 m2
  while [ "$i" -lt 25 ]; do
    if mkdir "$d" 2>/dev/null; then
      printf '%s' "$ARMED_LOCK_TOKEN" > "$d/owner" 2>/dev/null || true
      # Test seam: stolen-and-replaced-while-held cannot be produced by timing.
      [ -n "${CC_STOP_TEST_POST_LOCK_HOOK:-}" ] && . "$CC_STOP_TEST_POST_LOCK_HOOK"
      return 0
    fi
    # Staleness is a 30s question, so it does not need probing at 20 Hz — every
    # fifth attempt keeps a contended wait at 3 forks instead of 75.
    if [ "$(( i % 5 ))" -eq 0 ]; then
      now="$(date +%s 2>/dev/null)" || return 1
      m1="$(_lock_mtime "$d")"
      if [ -n "$m1" ] && [ "$(( now - m1 ))" -gt 30 ]; then
        # Steal only the lock we just measured stale: an unchanged mtime
        # identifies the same lock (a replacement is >30s newer), and the `mv`
        # makes the removal single-winner. A blind `rm -rf` could delete a
        # replacement owner's fresh lock.
        m2="$(_lock_mtime "$d")"
        if [ "$m1" = "$m2" ] && mv "$d" "$d.stale.$$" 2>/dev/null; then
          rm -rf "$d.stale.$$" 2>/dev/null
        fi
        # Counted as an attempt: an unremovable lock must not loop forever here.
        i=$((i+1))
        continue
      fi
    fi
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i+1))
  done
  return 1
}
armed_unlock() { # release ONLY our own lock
  # An owner that stalled past the staleness window and resumed must not delete
  # the replacement's lock. Not ours = leave it: that costs one staleness
  # window, deleting it costs mutual exclusion.
  local d="$1.lock"
  [ "$(cat "$d/owner" 2>/dev/null)" = "$ARMED_LOCK_TOKEN" ] || return 0
  rm -rf "$d" 2>/dev/null
}

armed_rewrite() { # $1=armed file; body on stdin
  local f="$1" tmp
  tmp="$(mktemp "$f.XXXXXX" 2>/dev/null)" || return 1
  if cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

bump_blocks() { # $1=file $2=current — rewrite with blocks incremented.
  # Re-reads the counter inside the lock (a stale value is the lost update).
  # Non-zero when the increment could NOT be persisted — including a lock we
  # could not get — and the caller must then fail OPEN: blocking on an
  # unpersisted counter bypasses the cap into unlimited blocking.
  local f="$1" b cur
  armed_lock "$f" || return 1
  cur="$(raw_field "$f" blocks)"
  is_bounded_num "$cur" || cur="$2"
  b=$(( cur + 1 ))
  { grep -v '^blocks=' "$f" 2>/dev/null
    echo "blocks=$b"
  } | armed_rewrite "$f" || { armed_unlock "$f"; return 1; }
  armed_unlock "$f"
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

# The plan scope, from the canonical script, resolved once per run. The hook
# must still work if that script is missing (it degrades loudly elsewhere), so
# an empty answer falls back to the documented default rather than to "no
# pathspecs", which git would read as the whole tree.
PLAN_PATHS_CACHE=""
plan_paths() {
  if [[ -z "$PLAN_PATHS_CACHE" ]]; then
    local fpsh="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/gate-fingerprint.sh}"
    [[ -n "$fpsh" && -f "$fpsh" ]] && PLAN_PATHS_CACHE="$(bash "$fpsh" --plan-paths 2>/dev/null)"
    [[ -n "$PLAN_PATHS_CACHE" ]] || PLAN_PATHS_CACHE="${CC_CODEX_PLAN_PATHS:-docs/plans docs/PLANS}"
  fi
  printf '%s' "$PLAN_PATHS_CACHE"
}

dirty_plans() {
  # The scope comes from gate-fingerprint.sh, so the dirt predicate and the
  # fingerprint can never disagree about what "plan documents" means.
  local paths; paths="$(plan_paths)"
  # `set -f` (in a subshell) disables globbing so the pathspecs reach git
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

# Mirrored in scripts/lib.sh (this hook stays dependency-free) — change both.
gate_baseline() { # $1=armed file — the code state this gate last RELEASED, else
  # the state at arming. Empty = pre-0.9 armed file, which keeps the dirty-tree
  # test until its first release, so an upgrade never changes a live gate.
  local v
  v="$(raw_field "$1" released_fp)"
  [[ -n "$v" ]] || v="$(raw_field "$1" fp_at_arming)"
  printf '%s' "$v"
}

has_unreviewed_work() { # $1=baseline fp  $2=current fp  $3=legacy dirt predicate
  # No baseline (pre-0.9) or no current fingerprint both fall back to the
  # dirty-tree predicate: a weakened gate beats none.
  { [[ -n "$1" && -n "$2" ]]; } || { "$3"; return; }
  [[ "$1" != "$2" ]]
}

reviewed_fingerprint() { # $1=thread [$2="plan"] [$3=cycle cut]
  # What the dispatch that earned the verdict actually saw, not the worktree at
  # turn-end. In order: the `fp=` stamped into the verdict's own log record;
  # else <thread>.dispatch-fp, the LATEST dispatch, which is right only while
  # that IS the verdict's dispatch. Neither -> AMBIGUOUS, returned verbatim so
  # the caller refuses to release. Full rule: scripts/last-verdict.sh.
  #
  # $2="plan" selects the plan-scoped snapshot: comparing a whole-tree hash
  # against a pathspec hash can never be equal, and re-blocked to the cap.
  local v f="$STATE_DIR/$1.dispatch-fp" flag="--fp"
  # The plan gate releases on log GROWTH, so its releasing dispatch is the LAST.
  if [[ "${2:-}" == "plan" ]]; then f="$STATE_DIR/$1.dispatch-fp-plan"; flag="--fp-plan-latest"; fi
  v="$(bash "$VERDICT_SH" "$STATE_DIR/$1.log" "${3:-0}" "$flag" 2>/dev/null | tr -d '[:space:]')"
  [[ "$v" == "AMBIGUOUS" ]] && { printf 'AMBIGUOUS'; return 0; }
  [[ -n "$v" ]] || v="$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')"
  # Nothing records what was dispatched: keep blocking rather than stamping the
  # current tree. Costs a round, not a deadlock — the next dispatch settles it.
  [[ "$v" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || v="AMBIGUOUS"   # SHA-1 or SHA-256 object id
  printf '%s' "$v"
}

consume_idle_verdicts() { # $1=armed file $2=thread
  # With no cycle open, a verdict appended since the last cut answers nothing —
  # and left in place it BANKS: the next cycle finds that APPROVE already past
  # the offset and releases without a review. /autoreview's own arming produces
  # exactly that, which shipped the first change after arming ungated. Runs for
  # pre-0.9 files too; their fingerprint fields stay untouched.
  #
  # OFFSET ONLY — never rebaseline_cycle, which resets blocks=0: revert,
  # consume, reapply would then buy a full cap again, repeatably. Only an earned
  # release refills the budget.
  #
  # The growth test comes BEFORE the lock (an idle turn is the common case and
  # must not pay a lock cycle), and the offset is re-read inside it, since a
  # racing full-file rewrite would otherwise drop the other writer's field.
  # No lock, skip: a missed advance costs one blocked turn.
  local f="$1" t="$2" now off
  off="$(raw_field "$f" log_bytes_at_arming)"
  is_bounded_num "$off" || return 0
  now="$(log_size "$t")"
  [[ "$now" -ne "$off" ]] || return 0
  armed_lock "$f" || return 0
  off="$(raw_field "$f" log_bytes_at_arming)"
  if is_bounded_num "$off" && [[ "$now" -ne "$off" ]]; then
    { grep -v -e '^log_bytes_at_arming=' "$f" 2>/dev/null
      echo "log_bytes_at_arming=$now"
    } | armed_rewrite "$f" || true
  fi
  armed_unlock "$f"
  return 0
}

rebaseline_cycle() { # $1=armed file $2=fingerprint $3=thread — start a new cycle.
  # All three move together or the next cycle runs on stale state:
  #   released_fp          what was approved, so a later edit re-arms the gate;
  #   log_bytes_at_arming  advanced, so this verdict cannot release the next cycle;
  #   blocks=0             a fresh budget, refilled only by a real release.
  # Returns non-zero on failure; the caller releases anyway — a persisted marker
  # is not worth withholding an earned APPROVE over.
  local f="$1" fp="$2" size
  if [[ -z "$fp" ]]; then
    echo "cc-codex-triage: released, but the code fingerprint is unavailable so the release could not be recorded — the next turn re-evaluates from the previous baseline." >&2
    return 1
  fi
  size="$(log_size "$3")"
  if ! armed_lock "$f"; then
    echo "cc-codex-triage: released, but the armed-state lock could not be acquired so the release was not recorded — the next turn re-evaluates from the previous baseline." >&2
    return 1
  fi
  if ! { grep -v -e '^released_fp=' -e '^blocks=' -e '^log_bytes_at_arming=' "$f" 2>/dev/null
         echo "released_fp=$fp"
         echo "log_bytes_at_arming=$size"
         echo "blocks=0"
       } | armed_rewrite "$f"; then
    armed_unlock "$f"
    echo "cc-codex-triage: released, but could not write $f (state dir not writable?) — the next turn may re-block. Re-arm to continue." >&2
    return 1
  fi
  armed_unlock "$f"
}

# Resolved once. A missing parser must not be guessed either way — a faked
# APPROVE stamps unreviewed code, "no verdict" caps every cycle on a broken
# install — so the gate is skipped loudly instead, touching no state.
VERDICT_SH="${PLUGIN_ROOT:+$PLUGIN_ROOT/scripts/last-verdict.sh}"
VERDICT_SH_OK=1
if [[ -z "$VERDICT_SH" || ! -f "$VERDICT_SH" ]]; then
  echo "cc-codex-triage: last-verdict.sh not found next to the hook — cannot read thread verdicts, skipping the autoreview gate for this turn." >&2
  VERDICT_SH_OK=0
fi

# ── Gate TTL pre-pass ───────────────────────────────────────────────────────
# An armed gate older than 14 days is stale — a month-old gate re-firing on a
# reused branch name is the audited hazard. Runs over BOTH armed files before
# either gate evaluates: allow/emit_block exit the whole hook, so inline expiry
# would suppress or orphan the other gate.
# Fail-open: missing/malformed/future armed_at skips TTL for that file, and an
# expired file that cannot be removed is treated as absent for THIS run only.
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
    # Expiry mutates armed state like any other write, so it takes the same
    # lock and re-reads inside it: a re-arm that happened while we waited must
    # not be expired on the strength of the value measured outside.
    if armed_lock "$f"; then
      armed_at="$(raw_field "$f" armed_at)"
      if ! is_num "$armed_at" || [[ "${#armed_at}" -gt 12 ]] || [[ "$armed_at" -gt "$NOW" ]] \
         || [[ $(( NOW - armed_at )) -le "$GATE_TTL" ]]; then
        armed_unlock "$f"; continue              # re-armed while we waited
      fi
      rm -f "$f" 2>/dev/null
      armed_unlock "$f"
    fi
    # Lock unavailable or removal failed: same outcome — the file is still
    # there, so treat the gate as absent this turn rather than letting it block.
    if [[ ! -e "$f" ]]; then
      echo "$kind gate expired after 14 days (armed $(epoch_date "$armed_at")) — removed; re-arm with /$kind on." >&2
    else
      echo "$kind gate expired after 14 days (armed $(epoch_date "$armed_at")) but could not be removed (state dir not writable, or its lock is held) — ignoring it for this turn; re-arm with /$kind on." >&2
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
  ap_fp="$(code_fingerprint --plan)"
fi

# Answered once per gate: gate_baseline reads the armed file, and the fallback
# arm of has_unreviewed_work runs a `git status` — both were evaluated twice,
# once for the idle pre-pass and again for the gate itself.
AR_OPEN=0; AP_OPEN=0
if [[ "$AR_LIVE" -eq 1 ]]; then
  has_unreviewed_work "$(gate_baseline "$AR")" "$ar_fp" dirty_code && AR_OPEN=1
  [[ "$AR_OPEN" -eq 1 ]] || consume_idle_verdicts "$AR" "$ar_thread"
fi
if [[ "$AP_LIVE" -eq 1 ]]; then
  has_unreviewed_work "$(gate_baseline "$AP")" "$ap_fp" dirty_plans && AP_OPEN=1
  [[ "$AP_OPEN" -eq 1 ]] || consume_idle_verdicts "$AP" "$ap_thread"
fi

# ── /autoreview ─────────────────────────────────────────────────────────────
if [[ "$AR_OPEN" -eq 1 ]]; then
  thread="$ar_thread"
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
    # The cut makes the verdict self-sufficient: an APPROVE can only come from
    # content appended after arming. No .rounds check — /thread-new resets it.
    # An APPROVE that cannot be tied to a dispatched state approves nothing
    # identifiable, and releasing would stamp whatever the worktree holds NOW.
    # A pre-0.9 armed file is exempt: it has no fingerprint model, and keeps 0.8
    # semantics until its first release (the documented upgrade path).
    ar_release=false
    if [[ "$verdict" == "APPROVE" ]]; then
      ar_released="$(reviewed_fingerprint "$thread" "" "$log_off")"
      [[ "$ar_released" == "AMBIGUOUS" && -z "$(gate_baseline "$AR")" ]] && ar_released="$ar_fp"
      if [[ "$ar_released" == "AMBIGUOUS" ]]; then
        echo "autoreview: the APPROVE on thread $thread cannot be tied to a dispatched state (no fingerprint in its record, and no sidecar that still describes it), so what it approved cannot be established — not releasing. Re-review to settle it." >&2
      else
        ar_release=true
      fi
    fi
    if $ar_release; then
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

# ── /autoplan ───────────────────────────────────────────────────────────────
if [[ "$AP_OPEN" -eq 1 ]]; then
  thread="$ap_thread"
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
  # Release when the thread log changed size since arming: ANY dispatch appends,
  # and unlike .rounds the log is not touched by /thread-new. Known cap-bounded
  # edge: a post-arming rotation leaving the log EXACTLY the snapshot size reads
  # as "no dispatch" — fails toward blocking, never toward a false release.
  elif [[ "$log_now" -ne "$log_off" ]]; then
    # A dispatch happened this cycle — release, recording the plan state it
    # covered and the new log baseline, so the NEXT plan edit needs its own.
    ap_released="$(reviewed_fingerprint "$thread" plan "$log_off")"
    # Same upgrade carve-out as autoreview: a pre-0.9 armed file keeps 0.8
    # semantics until its first release.
    if [[ "$ap_released" == "AMBIGUOUS" && -z "$(gate_baseline "$AP")" ]]; then
      ap_released="$ap_fp"
    fi
    if [[ "$ap_released" == "AMBIGUOUS" ]]; then
      # The log grew, but nothing records which plan state that growth was
      # dispatched against. Releasing would re-baseline to whatever the plan
      # documents hold NOW — including edits made after the dispatch, which
      # nobody stress-tested. Block instead; the next dispatch stamps its own
      # record. Same reasoning as the autoreview side.
      echo "autoplan: the plan thread grew, but nothing records which plan state that dispatch saw (no fingerprint in the record, no usable sidecar) — not releasing. Dispatch again to settle it." >&2
      if [[ "$blocks" -lt "$cap" ]] && n="$(bump_blocks "$AP" "$blocks")"; then
        emit_block "autoplan armed: the plan thread has grown, but nothing records which plan state that dispatch covered, so the current plan cannot be treated as stress-tested. Read $CMD_DIR/plan.md and follow its steps with --once --thread $thread --lens $lens. Round $n/$cap. Disarm with the autoplan command (off)."
      fi
    else
      rebaseline_cycle "$AP" "$ap_released" "$thread" || true   # diagnoses itself
      # Plan edits made AFTER the releasing dispatch are not covered by it, so
      # open the next cycle now rather than ending the turn on them.
      if [[ -n "$ap_released" && -n "$ap_fp" && "$ap_released" != "$ap_fp" ]]; then
        nblocks="$(raw_field "$AP" blocks)"; is_bounded_num "$nblocks" || nblocks=0
        if [[ "$nblocks" -lt "$cap" ]] && n="$(bump_blocks "$AP" "$nblocks")"; then
          emit_block "autoplan armed: the plan documents changed after the dispatch that released the last cycle, so the current plan has not been stress-tested. Read $CMD_DIR/plan.md and follow its steps with --once --thread $thread --lens $lens. Round $n/$cap. Disarm with the autoplan command (off)."
        fi
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

allow
