#!/usr/bin/env bash
# Machine-readable required-review state bound to an exact clean Git candidate.
#
# begin <thread> --base <ref> --spec <repo-relative-path> --cap N
#                                capture a clean HEAD/tree candidate
# advisory-check <thread>        refuse advisory use of a required thread
# record <thread> <claim-token>   record the latest post-begin verdict
# abort <thread> <dispatch-failure|timeout|tool-failure> <claim-token>
#                                release a pending round after no dispatch result
# check <thread>                 verify APPROVE still covers current HEAD/tree
# reset <thread>                 clear terminal/review state when no dispatch is live
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_HELPER="$SELF_DIR/state-dir.sh"
VERDICT_HELPER="$SELF_DIR/verdict.sh"
ROUND_HELPER="$SELF_DIR/round-counter.sh"
. "$SELF_DIR/dir-lock.sh"

usage() {
  echo "usage: review-state.sh begin <thread> --base <ref> --spec <repo-relative-path> --cap N [--integration] | header <thread> | preflight <thread> (prompt on stdin) | advisory-check <thread> | record <thread> <claim-token> | abort <thread> <dispatch-failure|timeout|tool-failure> <claim-token> | check <thread> | renew <thread> --by <who> | reset <thread>" >&2
  exit 1
}
die() { _code="$1"; shift; echo "$*" >&2; exit "$_code"; }

VERB="${1:-}"; THREAD="${2:-}"
[ -n "$VERB" ] && [ -n "$THREAD" ] || usage
case "$THREAD" in *[!a-zA-Z0-9_.-]*|'') echo "thread name must be [a-zA-Z0-9_.-]+" >&2; exit 1 ;; esac

ROOT="$(bash "$STATE_HELPER" --root)" || exit $?
if ! git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  case "$VERB" in advisory-check|reset|preflight) ;; *) die 7 "required review needs a Git repository" ;; esac
fi
cd "$ROOT" || exit 7
# preflight runs before every dispatch, including --oneshot, which must leave no state behind.
if [ "$VERB" = preflight ]; then STATE_DIR="$(bash "$STATE_HELPER" --read-only)" || exit $?
else STATE_DIR="$(bash "$STATE_HELPER")" || exit $?; fi
CANDIDATE="$STATE_DIR/$THREAD.candidate"
REVIEW_STATE="$STATE_DIR/$THREAD.review-state"
APPROVED="$STATE_DIR/$THREAD.approved"
LOOP_STATE="$STATE_DIR/$THREAD.review-loop"
ACTIVE_LEASE="$STATE_DIR/$THREAD.active"
REVIEW_LOCK="$STATE_DIR/$THREAD.review-lock"
RECLAIM_LOCK="$STATE_DIR/$THREAD.review-lock-reclaim"
RECORD_TMP=""
dir_lock_init "$REVIEW_LOCK" "$RECLAIM_LOCK"

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
  for _suffix in candidate review-state review-loop approved log rounds dispatch-receipt; do
    _path="$STATE_DIR/$THREAD.$_suffix"
    [ ! -L "$_path" ] || { echo "refusing symlinked required-review state: $_path" >&2; exit 7; }
    [ ! -e "$_path" ] || [ -f "$_path" ] \
      || { echo "required-review state is not a regular file: $_path" >&2; exit 7; }
  done
}
cleanup_review_locks() {
  [ -z "$RECORD_TMP" ] || rm -f "$RECORD_TMP" 2>/dev/null
  dir_lock_release_all
}
acquire_review_lock() {
  trap cleanup_review_locks EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _waits=0
  while ! dir_lock_acquire; do
    dir_lock_safe "$REVIEW_LOCK" && dir_lock_safe "$RECLAIM_LOCK" \
      || die 7 "required-review lock is unsafe"
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
write_state() { # status verdict eligible head tree round reason
  _base="$(field "$CANDIDATE" base_sha)"; _spec="$(field "$CANDIDATE" spec_path)"
  _cap="$(field "$CANDIDATE" cap)"; _start="$(field "$CANDIDATE" loop_start_round)"
  _claim="$(field "$CANDIDATE" claim_token)"
  printf 'version=2\nstatus=%s\nverdict=%s\ngate_eligible=%s\nhead=%s\ntree=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nloop_start_round=%s\nclaim_token=%s\nround=%s\nreason=%s\ntimestamp=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$_base" "$_spec" "$_cap" "$_start" "$_claim" "$6" "$7" "$(timestamp)" \
    | atomic_write "$REVIEW_STATE"
}
write_loop_state() { # base spec cap start attempts — renewals recorded by `renew` are carried over
  _renewals="$(field "$LOOP_STATE" renewals)"; _renewed_by="$(field "$LOOP_STATE" renewed_by)"
  printf 'version=1\nbase_sha=%s\nspec_path=%s\ncap=%s\nstart_round=%s\nattempts=%s\nrenewals=%s\nrenewed_by=%s\ntimestamp=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "${_renewals:-0}" "$_renewed_by" "$(timestamp)" | atomic_write "$LOOP_STATE"
}
assert_claim() {
  _provided="$1"; _expected="$(field "$CANDIDATE" claim_token)"
  case "$_expected" in
    ''|*[!0-9a-f]*) die 10 "INVALID_CLAIM_STATE: inspect saved state; follow /thread-new Recovery before resetting this thread" ;;
  esac
  case "${#_expected}" in 40|64) ;; *) die 10 "INVALID_CLAIM_STATE: inspect saved state; follow /thread-new Recovery before resetting this thread" ;; esac
  [ "$_provided" = "$_expected" ] || die 10 "CLAIM_MISMATCH: required-review round belongs to another invocation"
}

assert_state_files_safe
# No state directory means no claim: preflight has nothing to check and must not create one.
if [ "$VERB" = preflight ] && [ ! -d "$STATE_DIR" ]; then cat >/dev/null; echo "NO_REQUIRED_CLAIM"; exit 0; fi
acquire_review_lock

case "$VERB" in
  header|preflight)
    # The four header lines are copied from the claimed candidate, never typed. `preflight`
    # compares a prompt with them BEFORE the paid dispatch: a short SHA or a wrong spec path used
    # to surface only after the call, as STALE (prompt_scope_mismatch), with the round spent.
    [ $# -eq 2 ] || usage
    # preflight runs before every dispatch: with no live required claim there is nothing to check,
    # and a prompt cannot switch the check off by leaving out its own first line.
    if [ "$VERB" = preflight ] && [ "$(field "$REVIEW_STATE" status 2>/dev/null)" != PENDING ]; then
      cat >/dev/null; echo "NO_REQUIRED_CLAIM"; exit 0
    fi
    [ -f "$CANDIDATE" ] || die 10 "NO_PENDING_REVIEW: run begin first"
    H_BASE="$(field "$CANDIDATE" base_sha)"; H_HEAD="$(field "$CANDIDATE" head)"; H_SPEC="$(field "$CANDIDATE" spec_path)"
    [ -n "$H_BASE" ] && [ -n "$H_HEAD" ] && [ -n "$H_SPEC" ] || die 10 "INVALID_CLAIM_STATE: candidate record is incomplete"
    HEADER="$(printf 'REQUIRED_REVIEW\nBASE_SHA: %s\nCANDIDATE_SHA: %s\nSPEC_PATH: %s' "$H_BASE" "$H_HEAD" "$H_SPEC")"
    if [ "$VERB" = header ]; then printf '%s\n' "$HEADER"; exit 0; fi
    PROMPT_IN="$(cat)"
    [ "$(printf '%s\n' "$PROMPT_IN" | head -n 4)" = "$HEADER" ] \
      || die 14 "PROMPT_SCOPE_MISMATCH before dispatch: the prompt must begin with exactly these lines (review-state.sh header $THREAD):
$HEADER"
    for H_LINE in "BASE_SHA: $H_BASE" "CANDIDATE_SHA: $H_HEAD" "SPEC_PATH: $H_SPEC" REQUIRED_REVIEW; do
      [ "$(printf '%s\n' "$PROMPT_IN" | grep -cxF -- "$H_LINE")" -eq 1 ] \
        || die 14 "PROMPT_SCOPE_MISMATCH before dispatch: '$H_LINE' must appear exactly once"
    done
    echo "PREFLIGHT_OK head=$H_HEAD"
    ;;

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
    BASE_REF=""; SPEC_PATH=""; CAP=""; INTEGRATION=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --integration) INTEGRATION=true; shift ;;
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
          && die 10 "$LAST_STATUS: report missing approval and continue safe work; a new review budget needs user authorization, not a reset workaround"
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
        || die 10 "REVIEW_CONTRACT_CHANGED: restore the original base/spec/cap, or start a new lifecycle for an authorized contract change"
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
    # An integration round re-earns an approval after the target was merged into an approved
    # candidate and nothing else changed: HEAD is a merge whose first parent is that candidate.
    # It is a real round, reviewing the integration, but it does not spend the review budget —
    # frequent target merges would otherwise use up the cap without a single new finding.
    INTEGRATION_OF=""
    if $INTEGRATION; then
      # Allowed right after the approval, or again after a technical failure of an integration
      # claim for this same HEAD (ABORTED, NO_FINDINGS). A real REQUEST_CHANGES never qualifies.
      PREV_INTEG="$(field "$CANDIDATE" integration_of)"
      # The link to the approved candidate is the one the failed claim recorded: a later record
      # revokes the .approved file, so it cannot be read back from there.
      case "$LAST_STATUS" in
        APPROVED)
          [ -f "$APPROVED" ] || die 10 "INTEGRATION_REFUSED: no recorded approval to integrate"
          INTEGRATION_OF="$(field "$APPROVED" head)" ;;
        ABORTED|NO_FINDINGS)
          [ -n "$PREV_INTEG" ] && [ "$(field "$CANDIDATE" head)" = "$HEAD_SHA" ] \
            || die 10 "INTEGRATION_REFUSED: only a failed integration claim for this same HEAD can be retried; this thread's last result is $LAST_STATUS"
          INTEGRATION_OF="$PREV_INTEG" ;;
        *) die 10 "INTEGRATION_REFUSED: an integration round follows an approved candidate; this thread's last result is ${LAST_STATUS:-none}" ;;
      esac
      [ "$(git rev-list --parents -n 1 HEAD 2>/dev/null | wc -w | tr -d ' ')" -eq 3 ] \
        && [ "$(git rev-parse HEAD^1 2>/dev/null)" = "$INTEGRATION_OF" ] \
        || die 10 "INTEGRATION_REFUSED: HEAD must be a merge whose first parent is the approved candidate $INTEGRATION_OF; review other changes as a normal round"
      ATTEMPT="$ATTEMPTS"
    else
      if [ "$ATTEMPTS" -ge "$CAP" ]; then
        [ -f "$CANDIDATE" ] \
          && write_state CAP_REACHED NONE false "$HEAD_SHA" "$TREE_SHA" "$CURRENT_ROUND" cap >/dev/null
        die 10 "CAP_REACHED: required review already claimed $CAP attempt(s)"
      fi
      ATTEMPT=$((ATTEMPTS + 1))
    fi
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
    printf 'version=2\nhead=%s\ntree=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nloop_start_round=%s\nattempt=%s\nclaim_token=%s\nround_before=%s\nlog_bytes=%s\nlog_gen=%s\nintegration_of=%s\ntimestamp=%s\n' \
      "$HEAD_SHA" "$TREE_SHA" "$BASE_SHA" "$SPEC_PATH" "$CAP" "$LOOP_START" "$ATTEMPT" "$CLAIM_TOKEN" "$CURRENT_ROUND" "$LOG_BYTES" "$LOG_GEN" "$INTEGRATION_OF" "$(timestamp)" \
      | atomic_write "$CANDIDATE" || exit 1
    write_state PENDING NONE false "$HEAD_SHA" "$TREE_SHA" "$(round_now)" awaiting_verdict || exit 1
    if [ -n "$INTEGRATION_OF" ]; then
      echo "PENDING head=$HEAD_SHA tree=$TREE_SHA claim=$CLAIM_TOKEN attempt=$ATTEMPT/$CAP integration_of=$INTEGRATION_OF"
    else
      echo "PENDING head=$HEAD_SHA tree=$TREE_SHA claim=$CLAIM_TOKEN attempt=$ATTEMPT/$CAP"
    fi
    ;;

  record)
    [ $# -eq 3 ] || usage
    assert_no_live_dispatch
    [ -f "$CANDIDATE" ] || die 10 "NO_REQUIRED_CANDIDATE: begin a required-review round first"
    [ "$(field "$REVIEW_STATE" status)" = PENDING ] \
      || die 10 "NO_PENDING_REVIEW: begin a required-review round first"
    assert_claim "$3"
    LOG="$STATE_DIR/$THREAD.log"
    OFF=0
    OFF="$(field "$CANDIDATE" log_bytes)"; OFF="${OFF:-0}"
    OLD_GEN="$(field "$CANDIDATE" log_gen)"; OLD_GEN="${OLD_GEN:-0}"
    valid_decimal "$OFF" 12 && valid_decimal "$OLD_GEN" 9 \
      || die 10 "INVALID_CLAIM_STATE: inspect saved state; follow /thread-new Recovery before resetting this thread"
    NOW_GEN="$(cat "$STATE_DIR/$THREAD.log-gen" 2>/dev/null)" || NOW_GEN=""
    valid_decimal "$NOW_GEN" 9 || NOW_GEN=0
    [ "$OLD_GEN" = "$NOW_GEN" ] || OFF=0
    RECORD_TMP="$(mktemp "$STATE_DIR/$THREAD.review-record.XXXXXX")" || exit 1
    # Judge only the latest dispatch after the candidate cut. Otherwise a later
    # verdict-less/advisory pass could inherit an earlier required APPROVE and
    # its scope markers from the same post-cut window.
    tail -c "+$(( OFF + 1 ))" "$LOG" 2>/dev/null | awk '
      /^\[/ { record=$0 ORS; seen=1; next }
      seen { record=record $0 ORS }
      END { printf "%s", record }
    ' > "$RECORD_TMP"
    VERDICT="$(bash "$VERDICT_HELPER" "$RECORD_TMP" 2>/dev/null)"; VRC=$?
    [ "$VRC" -eq 0 ] || VERDICT=NONE
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"

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
    elif [ "$(field "$STATE_DIR/$THREAD.dispatch-receipt" status)" != complete ]; then
      STALE_REASON=dispatch_incomplete
    elif [ "$(field "$STATE_DIR/$THREAD.dispatch-receipt" claim_token)" != "$(field "$CANDIDATE" claim_token)" ] \
      || [ "$(field "$STATE_DIR/$THREAD.dispatch-receipt" head)" != "$C_HEAD" ] \
      || [ "$(field "$STATE_DIR/$THREAD.dispatch-receipt" tree)" != "$C_TREE" ]; then
      STALE_REASON=dispatch_candidate_mismatch
    fi
    if [ -n "$STALE_REASON" ]; then
      write_state STALE "$VERDICT" false "$HEAD_SHA" "$TREE_SHA" "$(round_now)" "$STALE_REASON" || exit 1
      if [ "$STALE_REASON" = dispatch_incomplete ]; then
        echo "STALE ($STALE_REASON): no completed dispatch receipt; inspect the dispatch error before retrying within the remaining review budget" >&2
      else
        echo "STALE ($STALE_REASON): verdict does not cover the current clean candidate" >&2
      fi
      exit 11
    fi
    case "$VERDICT" in
      APPROVE)
        write_state APPROVED APPROVE true "$C_HEAD" "$C_TREE" "$(round_now)" exact_candidate_approved || exit 1
        atomic_write "$APPROVED" < "$REVIEW_STATE" || exit 1
        echo "APPROVE head=$C_HEAD tree=$C_TREE"
        ;;
      REQUEST_CHANGES)
        # A blocking verdict with not one file:line finding is a tool failure, not a review outcome:
        # nothing can be fixed or refuted, so the attempt goes back to the budget.
        if ! awk '/^REPLY:/{r=1;next} /^PROMPT:/{r=0} r' "$RECORD_TMP" | grep -Eq '[A-Za-z0-9_./-]*[A-Za-z_/][A-Za-z0-9_./-]*:[0-9]+'; then
          L_ATTEMPTS="$(field "$LOOP_STATE" attempts)"
          if [ -z "$(field "$CANDIDATE" integration_of)" ] && valid_decimal "$L_ATTEMPTS" 7 && [ "$L_ATTEMPTS" -gt 0 ]; then
            write_loop_state "$(field "$LOOP_STATE" base_sha)" "$(field "$LOOP_STATE" spec_path)" \
              "$(field "$LOOP_STATE" cap)" "$(field "$LOOP_STATE" start_round)" "$((L_ATTEMPTS - 1))" || exit 1
          fi
          write_state NO_FINDINGS REQUEST_CHANGES false "$C_HEAD" "$C_TREE" "$(round_now)" empty_findings || exit 1
          echo "NO_FINDINGS: REQUEST_CHANGES without a single file:line finding; the attempt was not counted. Begin again and ask for the findings with their locations." >&2
          exit 10
        fi
        if [ "$C_ATTEMPT" -ge "$C_CAP" ]; then
          write_state CAP_REACHED REQUEST_CHANGES false "$C_HEAD" "$C_TREE" "$CURRENT_ROUND" cap || exit 1
          echo "CAP_REACHED: blocking findings remain after $C_CAP round(s)" >&2
          exit 10
        fi
        write_state REQUEST_CHANGES REQUEST_CHANGES false "$C_HEAD" "$C_TREE" "$(round_now)" blocking_findings_open || exit 1
        echo "REQUEST_CHANGES: resolve the findings, commit a new clean candidate when code changes, then begin and review again" >&2
        exit 10
        ;;
      *)
        if [ "$C_ATTEMPT" -ge "$C_CAP" ]; then
          write_state CAP_REACHED "$VERDICT" false "$C_HEAD" "$C_TREE" "$CURRENT_ROUND" cap || exit 1
          echo "CAP_REACHED: no approval after $C_CAP round(s)" >&2
          exit 10
        fi
        write_state NO_DECISION "$VERDICT" false "$C_HEAD" "$C_TREE" "$(round_now)" no_approve_verdict || exit 1
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
      || die 10 "INVALID_CLAIM_STATE: inspect saved state; follow /thread-new Recovery before resetting this thread"
    valid_decimal "$NOW_GEN" 9 || NOW_GEN=0
    [ "$CURRENT_ROUND" = "$ROUND_BEFORE" ] && [ "$NOW_BYTES" = "$OLD_BYTES" ] && [ "$NOW_GEN" = "$OLD_GEN" ] \
      || die 10 "ROUND_COMPLETED: record the finished dispatch instead of aborting its claim"
    LOOP_BASE_SHA="$(field "$LOOP_STATE" base_sha)"
    LOOP_SPEC_PATH="$(field "$LOOP_STATE" spec_path)"
    LOOP_CAP="$(field "$LOOP_STATE" cap)"
    LOOP_START="$(field "$LOOP_STATE" start_round)"
    LOOP_ATTEMPTS="$(field "$LOOP_STATE" attempts)"
    C_BASE_SHA="$(field "$CANDIDATE" base_sha)"
    C_SPEC_PATH="$(field "$CANDIDATE" spec_path)"
    C_CAP="$(field "$CANDIDATE" cap)"
    C_START="$(field "$CANDIDATE" loop_start_round)"
    C_ATTEMPT="$(field "$CANDIDATE" attempt)"
    case "$LOOP_CAP:$C_CAP" in [1-5]:[1-5]) ;; *) die 10 "INVALID_CLAIM_STATE: inspect saved state; follow /thread-new Recovery before resetting this thread" ;; esac
    valid_decimal "$LOOP_START" 7 && valid_decimal "$C_START" 7 \
      && valid_decimal "$LOOP_ATTEMPTS" 7 && valid_decimal "$C_ATTEMPT" 7 \
      || die 10 "INVALID_CLAIM_STATE: inspect saved state; follow /thread-new Recovery before resetting this thread"
    [ "$LOOP_BASE_SHA" = "$C_BASE_SHA" ] && [ "$LOOP_SPEC_PATH" = "$C_SPEC_PATH" ] \
      && [ "$LOOP_CAP" = "$C_CAP" ] && [ "$LOOP_START" = "$C_START" ] \
      || die 10 "INVALID_CLAIM_STATE: inspect saved state; follow /thread-new Recovery before resetting this thread"
    C_INTEGRATION="$(field "$CANDIDATE" integration_of)"
    [ "$LOOP_ATTEMPTS" = "$C_ATTEMPT" ] && { [ "$LOOP_ATTEMPTS" -gt 0 ] || [ -n "$C_INTEGRATION" ]; } \
      || die 10 "INVALID_CLAIM_STATE: inspect saved state; follow /thread-new Recovery before resetting this thread"
    # The unchanged round/log proof above establishes that no dispatch
    # completed. Return a reserved slot, if present, before publishing ABORTED.
    # A crash between these writes remains fail-closed: PENDING blocks begin,
    # and the attempt mismatch prevents a second abort from refunding twice.
    # An integration claim reserved no attempt, so it returns none.
    [ -n "$C_INTEGRATION" ] \
      || write_loop_state "$LOOP_BASE_SHA" "$LOOP_SPEC_PATH" "$LOOP_CAP" "$LOOP_START" "$((LOOP_ATTEMPTS - 1))" \
      || exit 1
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"
    write_state ABORTED NONE false "$HEAD_SHA" "$TREE_SHA" "$(round_now)" "$3" || exit 1
    die 10 "ABORTED: required-review round released after $3"
    ;;

  check)
    [ $# -eq 2 ] || usage
    assert_no_live_dispatch
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
      && [ -n "$(field "$APPROVED" base_sha)" ] \
      && [ -n "$(field "$APPROVED" spec_path)" ] \
      && [ -n "$(field "$APPROVED" claim_token)" ] \
      && [ "$(field "$APPROVED" claim_token)" = "$(field "$CANDIDATE" claim_token)" ] \
      && [ "$(field "$APPROVED" head)" = "$(field "$CANDIDATE" head)" ] \
      && [ "$(field "$APPROVED" tree)" = "$(field "$CANDIDATE" tree)" ] \
      && [ "$(field "$APPROVED" base_sha)" = "$(field "$CANDIDATE" base_sha)" ] \
      && [ "$(field "$APPROVED" spec_path)" = "$(field "$CANDIDATE" spec_path)" ] \
      || { echo "NO_APPROVAL" >&2; exit 10; }
    [ "$(round_now)" = "$(field "$APPROVED" round)" ] \
      && [ "$(field "$STATE_DIR/$THREAD.dispatch-receipt" status)" = complete ] \
      && [ "$(field "$STATE_DIR/$THREAD.dispatch-receipt" claim_token)" = "$(field "$APPROVED" claim_token)" ] \
      || die 10 "NO_APPROVAL: a newer dispatch or missing receipt requires review"
    clean_candidate || { echo "STALE: candidate is dirty" >&2; exit 11; }
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"
    [ "$HEAD_SHA" = "$(field "$APPROVED" head)" ] \
      && [ "$TREE_SHA" = "$(field "$APPROVED" tree)" ] \
      || { echo "STALE: approval belongs to another candidate" >&2; exit 11; }
    echo "CC_CODEX_REQUIRED_REVIEW APPROVE thread=$THREAD head=$HEAD_SHA tree=$TREE_SHA base_sha=$(field "$APPROVED" base_sha) spec_path=$(field "$APPROVED" spec_path)"
    ;;

  renew)
    # A new review budget on the same thread, after the user authorized it: base, spec and cap stay
    # pinned, the Codex conversation continues, and the renewal is recorded. Renaming the thread or
    # resetting its state to get a fresh budget lost the pinned contract and the budget history.
    [ $# -eq 4 ] && [ "$3" = --by ] && [ -n "$4" ] || usage
    assert_no_live_dispatch
    [ "$(field "$REVIEW_STATE" status)" = CAP_REACHED ] \
      || die 10 "RENEW_REFUSED: renew follows CAP_REACHED; the thread is $(field "$REVIEW_STATE" status)"
    [ -f "$LOOP_STATE" ] || die 10 "INVALID_CLAIM_STATE: no review loop to renew"
    case "$4" in *[!a-zA-Z0-9_.@\ -]*) die 1 "--by must name who authorized the budget ([a-zA-Z0-9_.@ -])" ;; esac
    R_BASE="$(field "$LOOP_STATE" base_sha)"; R_SPEC="$(field "$LOOP_STATE" spec_path)"
    R_CAP="$(field "$LOOP_STATE" cap)"; R_COUNT="$(field "$LOOP_STATE" renewals)"
    valid_decimal "${R_COUNT:-0}" 4 || R_COUNT=0
    R_COUNT=$(( ${R_COUNT:-0} + 1 ))
    { printf 'version=1\nbase_sha=%s\nspec_path=%s\ncap=%s\nstart_round=%s\nattempts=0\nrenewals=%s\nrenewed_by=%s\ntimestamp=%s\n' \
        "$R_BASE" "$R_SPEC" "$R_CAP" "$(round_now)" "$R_COUNT" "$4" "$(timestamp)"; } \
      | atomic_write "$LOOP_STATE" || exit 1
    rm -f "$CANDIDATE" "$STATE_DIR/$THREAD.dispatch-receipt" || die 7 "cannot clear the finished claim"
    write_state RENEWED NONE false "$(head_sha 2>/dev/null || true)" "$(tree_sha 2>/dev/null || true)" "$(round_now)" "budget_renewed_by_$R_COUNT" >/dev/null 2>&1 || true
    echo "RENEWED $THREAD: budget $R_COUNT of $R_CAP attempt(s) authorized by $4; base and spec unchanged"
    ;;

  reset)
    [ $# -eq 2 ] || usage
    assert_no_live_dispatch "${CC_CODEX_REVIEW_RESET_LEASE_PID:-}"
    rm -f "$CANDIDATE" "$REVIEW_STATE" "$LOOP_STATE" "$APPROVED" "$STATE_DIR/$THREAD.dispatch-receipt" \
      || die 7 "cannot reset required-review state"
    echo "RESET required-review state for $THREAD"
    ;;
  *) usage ;;
esac
