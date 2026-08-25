#!/usr/bin/env bash
# Machine-readable required-review state bound to an exact clean Git candidate.
#
# begin <thread> --base <ref> --spec <repo-relative-path> --cap N
#                                capture a clean HEAD/tree candidate
# record <thread> <foreground|background> [claim-token]
#                                record the latest post-begin verdict; only an
#                                unchanged foreground APPROVE is gate-eligible
# abort <thread> <dispatch-failure|timeout|tool-failure> <claim-token>
#                                release a pending round after no dispatch result
# check <thread>                 verify APPROVE still covers current HEAD/tree
# reset <thread>                 clear terminal/review state when no dispatch is live
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_HELPER="$SELF_DIR/state-dir.sh"
VERDICT_HELPER="$SELF_DIR/verdict.sh"
ROUND_HELPER="$SELF_DIR/round-counter.sh"

usage() {
  echo "usage: review-state.sh begin <thread> --base <ref> --spec <repo-relative-path> --cap N | advisory-check <thread> | record <thread> <foreground|background> [claim-token] | abort <thread> <dispatch-failure|timeout|tool-failure> <claim-token> | check <thread> | reset <thread>" >&2
  exit 1
}
die() { _code="$1"; shift; echo "$*" >&2; exit "$_code"; }

VERB="${1:-}"; THREAD="${2:-}"
[ -n "$VERB" ] && [ -n "$THREAD" ] || usage
case "$THREAD" in *[!a-zA-Z0-9_.-]*|'') echo "thread name must be [a-zA-Z0-9_.-]+" >&2; exit 1 ;; esac

if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "not inside a git repository" >&2
  exit 7
fi
cd "$ROOT" || exit 7
STATE_DIR="$(bash "$STATE_HELPER")" || exit $?
CANDIDATE="$STATE_DIR/$THREAD.candidate"
REVIEW_STATE="$STATE_DIR/$THREAD.review-state"
APPROVED="$STATE_DIR/$THREAD.approved"
LOOP_STATE="$STATE_DIR/$THREAD.review-loop"
ACTIVE_LEASE="$STATE_DIR/$THREAD.active"
REVIEW_LOCK="$STATE_DIR/$THREAD.review-lock"
RECLAIM_LOCK="$STATE_DIR/$THREAD.review-lock-reclaim"
RECORD_TMP=""

field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1; }
valid_decimal() { # $1=value $2=max length
  _decimal="$1"; _max_length="$2"
  case "$_decimal" in ''|0[0-9]*|*[!0-9]*) return 1 ;; esac
  [ "${#_decimal}" -le "$_max_length" ]
}
atomic_write() { # $1=path; body on stdin
  _dst="$1"; _tmp="$(mktemp "$_dst.tmp.XXXXXX")" || return 1
  umask 077
  if cat > "$_tmp" && mv -f "$_tmp" "$_dst"; then return 0; fi
  rm -f "$_tmp" 2>/dev/null
  return 1
}
assert_state_files_safe() {
  for _suffix in candidate review-state review-loop approved log rounds; do
    _path="$STATE_DIR/$THREAD.$_suffix"
    [ ! -L "$_path" ] || { echo "refusing symlinked required-review state: $_path" >&2; exit 7; }
    [ ! -e "$_path" ] || [ -f "$_path" ] \
      || { echo "required-review state is not a regular file: $_path" >&2; exit 7; }
  done
}
assert_lock_safe() {
  _lock="$1"
  [ ! -L "$_lock" ] || die 7 "refusing symlinked required-review lock: $_lock"
  [ ! -e "$_lock" ] || [ -d "$_lock" ] \
    || die 7 "required-review lock is not a directory: $_lock"
  [ ! -e "$_lock/owner" ] \
    || { [ ! -L "$_lock/owner" ] && [ -f "$_lock/owner" ]; } \
    || die 7 "required-review lock owner is unsafe: $_lock/owner"
}
lock_mtime_epoch() {
  _value="$(stat -c '%Y' "$1" 2>/dev/null)" && [ -n "$_value" ] \
    && { printf '%s' "$_value"; return 0; }
  stat -f '%m' "$1" 2>/dev/null
}
remove_owned_lock() {
  _lock="$1"
  [ ! -L "$_lock" ] || return 0
  [ -d "$_lock" ] || return 0
  [ ! -L "$_lock/owner" ] || return 0
  [ "$(cat "$_lock/owner" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$_lock/owner" 2>/dev/null
  rmdir "$_lock" 2>/dev/null || true
}
cleanup_review_locks() {
  [ -z "$RECORD_TMP" ] || rm -f "$RECORD_TMP" 2>/dev/null
  remove_owned_lock "$RECLAIM_LOCK"
  remove_owned_lock "$REVIEW_LOCK"
}
lock_is_stale() { # $1=lock directory
  _candidate_lock="$1"; _owner="$(cat "$_candidate_lock/owner" 2>/dev/null)"
  case "$_owner" in
    '')
      _now="$(date +%s 2>/dev/null)"; _modified="$(lock_mtime_epoch "$_candidate_lock")"
      case "$_now:$_modified" in :*|*:|*[!0-9:]*) return 1 ;; esac
      [ $((_now - _modified)) -gt 60 ]
      ;;
    0|0[0-9]*|*[!0-9]*) return 0 ;;
    *)
      [ "${#_owner}" -le 12 ] || return 0
      kill -0 "$_owner" 2>/dev/null && return 1
      return 0
      ;;
  esac
}
acquire_reclaim_lock() {
  _tries=0
  while [ "$_tries" -lt 100 ]; do
    assert_lock_safe "$RECLAIM_LOCK"
    if mkdir "$RECLAIM_LOCK" 2>/dev/null; then
      if (set -C; printf '%s\n' "$$" > "$RECLAIM_LOCK/owner") 2>/dev/null \
          && [ "$(cat "$RECLAIM_LOCK/owner" 2>/dev/null)" = "$$" ]; then
        return 0
      fi
      return 1
    fi
    if lock_is_stale "$RECLAIM_LOCK"; then
      _sampled="$(cat "$RECLAIM_LOCK/owner" 2>/dev/null)"
      _stale_reclaim="$RECLAIM_LOCK.stale.$$.$_tries"
      [ ! -e "$_stale_reclaim" ] && [ ! -L "$_stale_reclaim" ] || return 1
      if mv "$RECLAIM_LOCK" "$_stale_reclaim" 2>/dev/null; then
        _moved_owner="$(cat "$_stale_reclaim/owner" 2>/dev/null)"
        if [ "$_moved_owner" != "$_sampled" ]; then
          # Another contender replaced the sampled generation. Restore it when
          # possible; otherwise leave the current generation untouched and
          # discard only the displaced directory after its owner loses proof.
          if [ ! -e "$RECLAIM_LOCK" ] && [ ! -L "$RECLAIM_LOCK" ]; then
            mv "$_stale_reclaim" "$RECLAIM_LOCK" 2>/dev/null || true
          else
            rm -f "$_stale_reclaim/owner" 2>/dev/null
            rmdir "$_stale_reclaim" 2>/dev/null || true
          fi
          return 1
        fi
        rm -f "$_stale_reclaim/owner" 2>/dev/null
        rmdir "$_stale_reclaim" 2>/dev/null || true
        _tries=$((_tries + 1))
        continue
      fi
    fi
    return 1
  done
  return 1
}
try_reclaim_review_lock() {
  acquire_reclaim_lock || return 1
  assert_lock_safe "$REVIEW_LOCK"
  if [ ! -d "$REVIEW_LOCK" ]; then
    remove_owned_lock "$RECLAIM_LOCK"
    return 0
  fi
  _owner="$(cat "$REVIEW_LOCK/owner" 2>/dev/null)"
  _reclaim=false
  lock_is_stale "$REVIEW_LOCK" && _reclaim=true
  if $_reclaim; then
    [ "$(cat "$RECLAIM_LOCK/owner" 2>/dev/null)" = "$$" ] || return 1
    _stale="$REVIEW_LOCK.stale.$$"
    [ ! -e "$_stale" ] && [ ! -L "$_stale" ] \
      || die 7 "stale review lock path already exists"
    if mv "$REVIEW_LOCK" "$_stale" 2>/dev/null; then
      [ ! -L "$_stale" ] || { rm -f "$_stale"; die 7 "refused symlinked stale review lock"; }
      [ ! -L "$_stale/owner" ] || die 7 "refused unsafe stale review lock owner"
      [ "$(cat "$_stale/owner" 2>/dev/null)" = "$_owner" ] \
        || die 7 "review lock generation changed during reclaim"
      rm -f "$_stale/owner" 2>/dev/null
      rmdir "$_stale" 2>/dev/null || true
    fi
  fi
  remove_owned_lock "$RECLAIM_LOCK"
  $_reclaim
}
acquire_review_lock() {
  trap cleanup_review_locks EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _waits=0
  while :; do
    assert_lock_safe "$REVIEW_LOCK"
    assert_lock_safe "$RECLAIM_LOCK"
    if mkdir "$REVIEW_LOCK" 2>/dev/null; then
      if ! (set -C; printf '%s\n' "$$" > "$REVIEW_LOCK/owner") 2>/dev/null \
          || [ "$(cat "$REVIEW_LOCK/owner" 2>/dev/null)" != "$$" ]; then
        die 7 "cannot own review lock"
      fi
      return 0
    fi
    try_reclaim_review_lock && continue
    _waits=$((_waits + 1))
    [ "$_waits" -lt 100 ] || die 7 "required-review state is busy"
    sleep 0.05 2>/dev/null || sleep 1
  done
}
assert_no_live_dispatch() {
  _allowed_pid="${1:-}"
  [ ! -L "$ACTIVE_LEASE" ] || die 7 "refusing symlinked dispatch lease"
  [ ! -e "$ACTIVE_LEASE" ] || [ -f "$ACTIVE_LEASE" ] \
    || die 7 "dispatch lease is not a regular file: $ACTIVE_LEASE"
  _active="$(cat "$ACTIVE_LEASE" 2>/dev/null)"
  case "$_active" in
    ''|0|0[0-9]*|*[!0-9]*) return 0 ;;
  esac
  if [ "$_active" != "$_allowed_pid" ] && kill -0 "$_active" 2>/dev/null; then
    die 10 "thread dispatch is active: $THREAD"
  fi
}
timestamp() { date -u +%FT%TZ; }
head_sha() { git rev-parse --verify HEAD 2>/dev/null; }
tree_sha() { git rev-parse --verify 'HEAD^{tree}' 2>/dev/null; }
round_now() {
  bash "$ROUND_HELPER" "$STATE_DIR/$THREAD.rounds" \
    || die 7 "cannot read required-review round counter"
}
clean_candidate() {
  _status="$(git status --porcelain -uall --ignore-submodules=none 2>/dev/null)" || return 1
  [ -z "$_status" ]
}
prompt_scope_exact() {
  awk -v base="$2" -v head="$3" -v spec="$4" '
    /^PROMPT:/ { prompt=1; next }
    /^REPLY:/ { prompt=0 }
    !prompt { next }
    {
      if (substr($0, 1, 2) != "  ") bad=1
      line=substr($0, 3)
      lines[++n]=line
    }
    END {
      expected[1]="REQUIRED_REVIEW"
      expected[2]="BASE_SHA: " base
      expected[3]="CANDIDATE_SHA: " head
      expected[4]="SPEC_PATH: " spec
      if (bad || n < 4) exit 1
      for (i=1; i<=4; i++) if (lines[i] != expected[i]) exit 1
      for (i=1; i<=n; i++) for (j=1; j<=4; j++) if (lines[i] == expected[j]) count[j]++
      for (j=1; j<=4; j++) if (count[j] != 1) exit 1
    }
  ' "$1"
}
write_state() { # status verdict eligible mode head tree round reason
  _base="$(field "$CANDIDATE" base_sha)"; _spec="$(field "$CANDIDATE" spec_path)"
  _cap="$(field "$CANDIDATE" cap)"; _start="$(field "$CANDIDATE" loop_start_round)"
  _claim="$(field "$CANDIDATE" claim_token)"
  printf 'version=2\nstatus=%s\nverdict=%s\ngate_eligible=%s\nmode=%s\nhead=%s\ntree=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nloop_start_round=%s\nclaim_token=%s\nround=%s\nreason=%s\ntimestamp=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$_base" "$_spec" "$_cap" "$_start" "$_claim" "$7" "$8" "$(timestamp)" \
    | atomic_write "$REVIEW_STATE"
}
write_loop_state() { # base spec cap start attempts
  printf 'version=1\nbase_sha=%s\nspec_path=%s\ncap=%s\nstart_round=%s\nattempts=%s\ntimestamp=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$(timestamp)" | atomic_write "$LOOP_STATE"
}
assert_claim() {
  _provided="$1"; _expected="$(field "$CANDIDATE" claim_token)"
  case "$_expected" in
    ''|*[!0-9a-f]*) die 10 "INVALID_CLAIM_STATE: reset the required-review thread" ;;
  esac
  case "${#_expected}" in 40|64) ;; *) die 10 "INVALID_CLAIM_STATE: reset the required-review thread" ;; esac
  [ "$_provided" = "$_expected" ] || die 10 "CLAIM_MISMATCH: required-review round belongs to another invocation"
}

assert_state_files_safe
acquire_review_lock

case "$VERB" in
  advisory-check)
    [ $# -eq 2 ] || usage
    assert_no_live_dispatch
    [ ! -f "$CANDIDATE" ] \
      || die 10 "REQUIRED_THREAD_RESERVED: use a different --thread for advisory review, or /thread-new to discard the required-review state"
    echo "ADVISORY_READY thread=$THREAD"
    ;;

  begin)
    assert_no_live_dispatch
    shift 2
    BASE_REF=""; SPEC_PATH=""; CAP=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --base) [ $# -ge 2 ] || usage; BASE_REF="$2"; shift 2 ;;
        --spec) [ $# -ge 2 ] || usage; SPEC_PATH="$2"; shift 2 ;;
        --cap) [ $# -ge 2 ] || usage; CAP="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$BASE_REF" ] && [ -n "$SPEC_PATH" ] && [ -n "$CAP" ] || usage
    case "$CAP" in 1|2|3|4|5) ;; *) echo "required review cap must be 1..5" >&2; exit 1 ;; esac
    case "$SPEC_PATH" in /*|..|../*|*/../*) echo "spec must be a repo-relative path inside the repository" >&2; exit 1 ;; esac
    while [ "${SPEC_PATH#./}" != "$SPEC_PATH" ]; do SPEC_PATH="${SPEC_PATH#./}"; done
    case "$SPEC_PATH" in *[!a-zA-Z0-9_./-]*) echo "spec path must use [a-zA-Z0-9_./-] for a stable machine marker" >&2; exit 1 ;; esac
    [ ! -L "$SPEC_PATH" ] || { echo "required review spec must not be a symlink: $SPEC_PATH" >&2; exit 13; }
    [ -f "$SPEC_PATH" ] || { echo "spec file not found: $SPEC_PATH" >&2; exit 1; }
    git ls-files --error-unmatch -- "$SPEC_PATH" >/dev/null 2>&1 \
      || { echo "required review spec must be tracked in the clean candidate: $SPEC_PATH" >&2; exit 13; }
    BASE_SHA="$(git rev-parse --verify --end-of-options "$BASE_REF^{commit}" 2>/dev/null)" \
      || { echo "cannot resolve review base: $BASE_REF" >&2; exit 1; }
    clean_candidate || { echo "required review needs a clean candidate commit" >&2; exit 13; }
    HEAD_SHA="$(head_sha)" || { echo "required review needs an existing HEAD" >&2; exit 13; }
    git merge-base --is-ancestor "$BASE_SHA" "$HEAD_SHA" 2>/dev/null \
      || { echo "review base is not an ancestor of candidate HEAD: $BASE_SHA" >&2; exit 1; }
    TREE_SHA="$(tree_sha)" || exit 13
    CURRENT_ROUND="$(round_now)"
    LAST_STATUS="$(field "$REVIEW_STATE" status)"
    case "$LAST_STATUS" in
      PENDING) die 10 "PENDING: finish or abort the claimed review round before begin" ;;
      CAP_REACHED)
        [ -f "$CANDIDATE" ] \
          && die 10 "$LAST_STATUS: reset the thread before starting another required review"
        ;;
    esac
    if [ -f "$LOOP_STATE" ]; then
      LOOP_BASE_SHA="$(field "$LOOP_STATE" base_sha)"
      LOOP_SPEC_PATH="$(field "$LOOP_STATE" spec_path)"
      LOOP_CAP="$(field "$LOOP_STATE" cap)"
      LOOP_START="$(field "$LOOP_STATE" start_round)"
      ATTEMPTS="$(field "$LOOP_STATE" attempts)"
      [ -n "$LOOP_BASE_SHA" ] && [ -n "$LOOP_SPEC_PATH" ] \
        || { echo "invalid required review loop contract" >&2; exit 1; }
      case "$LOOP_CAP" in
        1|2|3|4|5) ;;
        *) echo "invalid required review loop cap" >&2; exit 1 ;;
      esac
      valid_decimal "$LOOP_START" 7 \
        || { echo "invalid required review loop state" >&2; exit 1; }
      [ "$LOOP_BASE_SHA" = "$BASE_SHA" ] \
        && [ "$LOOP_SPEC_PATH" = "$SPEC_PATH" ] \
        && [ "$LOOP_CAP" = "$CAP" ] \
        || die 10 "REVIEW_CONTRACT_CHANGED: reset the thread before changing required-review base, spec, or cap"
    else
      LOOP_START="$CURRENT_ROUND"
      ATTEMPTS=0
    fi
    valid_decimal "$LOOP_START" 7 && valid_decimal "$CURRENT_ROUND" 7 \
      || { echo "invalid required review loop state" >&2; exit 1; }
    [ "$CURRENT_ROUND" -ge "$LOOP_START" ] || { echo "required review round counter moved backwards" >&2; exit 1; }
    [ -n "$ATTEMPTS" ] || ATTEMPTS=$((CURRENT_ROUND - LOOP_START))
    valid_decimal "$ATTEMPTS" 7 \
      || { echo "invalid required review attempt state" >&2; exit 1; }
    if [ "$ATTEMPTS" -ge "$CAP" ]; then
      [ -f "$CANDIDATE" ] \
        && write_state CAP_REACHED NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$CURRENT_ROUND" cap >/dev/null
      die 10 "CAP_REACHED: required review already claimed $CAP attempt(s)"
    fi
    ATTEMPT=$((ATTEMPTS + 1))
    write_loop_state "$BASE_SHA" "$SPEC_PATH" "$CAP" "$LOOP_START" "$ATTEMPT" || exit 1
    # Deterministic race seam for concurrency tests: begin still owns the
    # review mutex here, before candidate/PENDING publication becomes coherent.
    [ -n "${CC_REVIEW_STATE_TEST_AFTER_LOOP_HOOK:-}" ] \
      && . "$CC_REVIEW_STATE_TEST_AFTER_LOOP_HOOK"
    CLAIMED_AT="$(date +%s 2>/dev/null)"
    case "$CLAIMED_AT" in ''|*[!0-9]*) die 7 "cannot timestamp required-review claim" ;; esac
    CLAIM_TOKEN="$(printf '%s\n' "$ROOT" "$THREAD" "$HEAD_SHA" "$TREE_SHA" "$ATTEMPT" "$$" "$CLAIMED_AT" \
      | git hash-object --stdin 2>/dev/null)"
    [ -n "$CLAIM_TOKEN" ] || die 7 "cannot create required-review claim token"
    LOG_BYTES="$(wc -c 2>/dev/null < "$STATE_DIR/$THREAD.log" | tr -d ' ')"; LOG_BYTES="${LOG_BYTES:-0}"
    LOG_GEN="$(cat "$STATE_DIR/$THREAD.log-gen" 2>/dev/null)" || LOG_GEN=""
    valid_decimal "$LOG_GEN" 9 || LOG_GEN=0
    printf 'version=2\nhead=%s\ntree=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nloop_start_round=%s\nattempt=%s\nclaim_token=%s\nround_before=%s\nlog_bytes=%s\nlog_gen=%s\ntimestamp=%s\n' \
      "$HEAD_SHA" "$TREE_SHA" "$BASE_SHA" "$SPEC_PATH" "$CAP" "$LOOP_START" "$ATTEMPT" "$CLAIM_TOKEN" "$CURRENT_ROUND" "$LOG_BYTES" "$LOG_GEN" "$(timestamp)" \
      | atomic_write "$CANDIDATE" || exit 1
    write_state PENDING NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$(round_now)" awaiting_verdict || exit 1
    echo "PENDING head=$HEAD_SHA tree=$TREE_SHA claim=$CLAIM_TOKEN attempt=$ATTEMPT/$CAP"
    ;;

  record)
    { [ $# -eq 3 ] || [ $# -eq 4 ]; } || usage
    assert_no_live_dispatch
    MODE="$3"; case "$MODE" in foreground|background) ;; *) usage ;; esac
    if [ -f "$CANDIDATE" ]; then
      [ "$(field "$REVIEW_STATE" status)" = PENDING ] \
        || die 10 "NO_PENDING_REVIEW: begin a required-review round first"
      [ $# -eq 4 ] || die 10 "CLAIM_REQUIRED: pass the token returned by begin"
      assert_claim "$4"
    else
      [ $# -eq 3 ] || usage
    fi
    LOG="$STATE_DIR/$THREAD.log"
    OFF=0
    if [ -f "$CANDIDATE" ]; then
      OFF="$(field "$CANDIDATE" log_bytes)"; OFF="${OFF:-0}"
      OLD_GEN="$(field "$CANDIDATE" log_gen)"; OLD_GEN="${OLD_GEN:-0}"
      valid_decimal "$OFF" 12 && valid_decimal "$OLD_GEN" 9 \
        || die 10 "INVALID_CLAIM_STATE: reset the required-review thread"
      NOW_GEN="$(cat "$STATE_DIR/$THREAD.log-gen" 2>/dev/null)" || NOW_GEN=""
      valid_decimal "$NOW_GEN" 9 || NOW_GEN=0
      [ "$OLD_GEN" = "$NOW_GEN" ] || OFF=0
    fi
    RECORD_TMP="$(mktemp "$STATE_DIR/$THREAD.review-record.XXXXXX")" || exit 1
    # Judge only the latest dispatch after the candidate cut. Otherwise a later
    # verdict-less/advisory pass could inherit an earlier required APPROVE and
    # its scope markers from the same post-cut window.
    tail -c "+$(( OFF + 1 ))" "$LOG" 2>/dev/null | awk '
      /^\[/ { record=$0 ORS; seen=1; next }
      seen { record=record $0 ORS }
      END { printf "%s", record }
    ' > "$RECORD_TMP"
    VERDICT="$(bash "$VERDICT_HELPER" strict "$RECORD_TMP" 2>/dev/null)"; VRC=$?
    [ "$VRC" -eq 0 ] || VERDICT=NONE
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"

    if [ "$MODE" = background ]; then
      write_state BACKGROUND_SINGLE_PASS "$VERDICT" false background "$HEAD_SHA" "$TREE_SHA" "$(round_now)" background_never_satisfies_gate || exit 1
      echo "BACKGROUND_SINGLE_PASS verdict=$VERDICT gate_eligible=false"
      exit 0
    fi

    [ -f "$CANDIDATE" ] || {
      write_state OBSERVED "$VERDICT" false foreground "$HEAD_SHA" "$TREE_SHA" "$(round_now)" no_required_candidate || exit 1
      echo "OBSERVED verdict=$VERDICT gate_eligible=false"
      exit 0
    }
    C_HEAD="$(field "$CANDIDATE" head)"; C_TREE="$(field "$CANDIDATE" tree)"
    C_BASE="$(field "$CANDIDATE" base_sha)"; C_SPEC="$(field "$CANDIDATE" spec_path)"
    C_CAP="$(field "$CANDIDATE" cap)"; C_ATTEMPT="$(field "$CANDIDATE" attempt)"
    LOOP_START="$(field "$CANDIDATE" loop_start_round)"; CURRENT_ROUND="$(round_now)"
    ROUND_BEFORE="$(field "$CANDIDATE" round_before)"
    case "$C_CAP" in 1|2|3|4|5) CAP_VALID=true ;; *) CAP_VALID=false ;; esac
    START_VALID=false
    valid_decimal "$LOOP_START" 7 && valid_decimal "$C_ATTEMPT" 7 \
      && valid_decimal "$ROUND_BEFORE" 7 && valid_decimal "$CURRENT_ROUND" 7 \
      && START_VALID=true
    # One STALE status, several distinct causes. Recording the same string for all of them left the
    # operator unable to choose a recovery — "the candidate moved" and "the reply cannot be
    # attributed to this dispatch" need opposite actions, and guessing wrong destroys a candidate
    # that was fine. Ordered from the state that invalidates everything downwards.
    STALE_REASON=""
    if ! $CAP_VALID; then STALE_REASON=malformed_cap
    elif ! $START_VALID; then STALE_REASON=malformed_round_state
    elif [ -z "$C_BASE" ] || [ -z "$C_SPEC" ]; then STALE_REASON=malformed_candidate_scope
    elif ! clean_candidate; then STALE_REASON=dirty_worktree
    elif [ "$HEAD_SHA" != "$C_HEAD" ]; then STALE_REASON=head_moved
    elif [ "$TREE_SHA" != "$C_TREE" ]; then STALE_REASON=tree_moved
    elif [ "$CURRENT_ROUND" -ne $((ROUND_BEFORE + 1)) ]; then STALE_REASON=round_counter_mismatch
    elif ! prompt_scope_exact "$RECORD_TMP" "$C_BASE" "$C_HEAD" "$C_SPEC"; then
      STALE_REASON=prompt_scope_mismatch
    fi
    if [ -n "$STALE_REASON" ]; then
      write_state STALE "$VERDICT" false foreground "$HEAD_SHA" "$TREE_SHA" "$(round_now)" "$STALE_REASON" || exit 1
      echo "STALE ($STALE_REASON): verdict does not cover the current clean candidate" >&2
      exit 11
    fi
    case "$VERDICT" in
      APPROVE)
        write_state APPROVED APPROVE true foreground "$C_HEAD" "$C_TREE" "$(round_now)" exact_candidate_approved || exit 1
        atomic_write "$APPROVED" < "$REVIEW_STATE" || exit 1
        echo "APPROVE head=$C_HEAD tree=$C_TREE"
        ;;
      REQUEST_CHANGES)
        if [ "$C_ATTEMPT" -ge "$C_CAP" ]; then
          write_state CAP_REACHED REQUEST_CHANGES false foreground "$C_HEAD" "$C_TREE" "$CURRENT_ROUND" cap || exit 1
          echo "CAP_REACHED: blocking findings remain after $C_CAP round(s)" >&2
          exit 10
        fi
        write_state REQUEST_CHANGES REQUEST_CHANGES false foreground "$C_HEAD" "$C_TREE" "$(round_now)" blocking_findings_open || exit 1
        echo "REQUEST_CHANGES: resolve the findings, commit a new clean candidate when code changes, then begin and review again" >&2
        exit 10
        ;;
      *)
        if [ "$C_ATTEMPT" -ge "$C_CAP" ]; then
          write_state CAP_REACHED "$VERDICT" false foreground "$C_HEAD" "$C_TREE" "$CURRENT_ROUND" cap || exit 1
          echo "CAP_REACHED: no approval after $C_CAP round(s)" >&2
          exit 10
        fi
        write_state NO_DECISION "$VERDICT" false foreground "$C_HEAD" "$C_TREE" "$(round_now)" no_approve_verdict || exit 1
        echo "NO_DECISION: required review did not return APPROVE" >&2
        exit 10
        ;;
    esac
    ;;

  abort)
    [ $# -eq 4 ] || usage
    assert_no_live_dispatch
    case "$3" in dispatch-failure|timeout|tool-failure) ;; *) usage ;; esac
    [ -f "$CANDIDATE" ] || die 10 "NO_REQUIRED_CANDIDATE"
    [ "$(field "$REVIEW_STATE" status)" = PENDING ] \
      || die 10 "NO_PENDING_REVIEW"
    assert_claim "$4"
    ROUND_BEFORE="$(field "$CANDIDATE" round_before)"; CURRENT_ROUND="$(round_now)"
    OLD_BYTES="$(field "$CANDIDATE" log_bytes)"; OLD_GEN="$(field "$CANDIDATE" log_gen)"
    NOW_BYTES="$(wc -c 2>/dev/null < "$STATE_DIR/$THREAD.log" | tr -d ' ')"; NOW_BYTES="${NOW_BYTES:-0}"
    NOW_GEN="$(cat "$STATE_DIR/$THREAD.log-gen" 2>/dev/null)" || NOW_GEN=""
    valid_decimal "$ROUND_BEFORE" 7 && valid_decimal "$CURRENT_ROUND" 7 \
      && valid_decimal "$OLD_BYTES" 12 && valid_decimal "$NOW_BYTES" 12 \
      && valid_decimal "$OLD_GEN" 9 \
      || die 10 "INVALID_CLAIM_STATE: reset the required-review thread"
    valid_decimal "$NOW_GEN" 9 || NOW_GEN=0
    [ "$CURRENT_ROUND" = "$ROUND_BEFORE" ] && [ "$NOW_BYTES" = "$OLD_BYTES" ] && [ "$NOW_GEN" = "$OLD_GEN" ] \
      || die 10 "ROUND_COMPLETED: record the finished dispatch instead of aborting its claim"
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"
    write_state ABORTED NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$(round_now)" "$3" || exit 1
    die 10 "ABORTED: required-review round released after $3"
    ;;

  check)
    [ $# -eq 2 ] || usage
    [ -f "$CANDIDATE" ] && [ -f "$REVIEW_STATE" ] && [ -f "$APPROVED" ] \
      || { echo "NO_APPROVAL" >&2; exit 10; }
    # APPROVED is published in two renames: first the live review state, then
    # its immutable approval copy. A failure between them must not combine a
    # new status with an older candidate identity. Exact byte equality proves
    # both files are one publication generation; the claim token then binds
    # that generation to the candidate captured by begin.
    cmp -s "$REVIEW_STATE" "$APPROVED" \
      || { echo "NO_APPROVAL: incomplete approval publication" >&2; exit 10; }
    [ "$(field "$REVIEW_STATE" status)" = APPROVED ] \
      && [ "$(field "$REVIEW_STATE" gate_eligible)" = true ] \
      && [ "$(field "$APPROVED" verdict)" = APPROVE ] \
      && [ "$(field "$APPROVED" mode)" = foreground ] \
      && [ -n "$(field "$APPROVED" base_sha)" ] \
      && [ -n "$(field "$APPROVED" spec_path)" ] \
      && [ -n "$(field "$APPROVED" claim_token)" ] \
      && [ "$(field "$APPROVED" claim_token)" = "$(field "$CANDIDATE" claim_token)" ] \
      && [ "$(field "$APPROVED" head)" = "$(field "$CANDIDATE" head)" ] \
      && [ "$(field "$APPROVED" tree)" = "$(field "$CANDIDATE" tree)" ] \
      && [ "$(field "$APPROVED" base_sha)" = "$(field "$CANDIDATE" base_sha)" ] \
      && [ "$(field "$APPROVED" spec_path)" = "$(field "$CANDIDATE" spec_path)" ] \
      || { echo "NO_APPROVAL" >&2; exit 10; }
    clean_candidate || { echo "STALE: candidate is dirty" >&2; exit 11; }
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"
    [ "$HEAD_SHA" = "$(field "$APPROVED" head)" ] \
      && [ "$TREE_SHA" = "$(field "$APPROVED" tree)" ] \
      || { echo "STALE: approval belongs to another candidate" >&2; exit 11; }
    echo "CC_CODEX_REQUIRED_REVIEW APPROVE thread=$THREAD head=$HEAD_SHA tree=$TREE_SHA base_sha=$(field "$APPROVED" base_sha) spec_path=$(field "$APPROVED" spec_path)"
    ;;

  reset)
    [ $# -eq 2 ] || usage
    assert_no_live_dispatch "${CC_CODEX_REVIEW_RESET_LEASE_PID:-}"
    rm -f "$CANDIDATE" "$REVIEW_STATE" "$LOOP_STATE" "$APPROVED" \
      || die 7 "cannot reset required-review state"
    echo "RESET required-review state for $THREAD"
    ;;
  *) usage ;;
esac
