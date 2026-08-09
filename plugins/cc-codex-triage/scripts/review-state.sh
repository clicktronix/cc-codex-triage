#!/usr/bin/env bash
# Machine-readable required-review state bound to an exact clean Git candidate.
#
# begin <thread> --base <ref> --spec <repo-relative-path> --cap N
#                                capture clean HEAD/tree/content fingerprint
# record <thread> <foreground|background>
#                                record the latest post-begin verdict; only an
#                                unchanged foreground APPROVE is gate-eligible
# stop <thread> <cap|divergence> record a hard stop (never an approval)
# check <thread>                 verify APPROVE still covers current HEAD/tree
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_HELPER="$SELF_DIR/state-dir.sh"
FP_HELPER="$SELF_DIR/gate-fingerprint.sh"
VERDICT_HELPER="$SELF_DIR/last-verdict.sh"

usage() {
  echo "usage: review-state.sh begin <thread> --base <ref> --spec <repo-relative-path> --cap N | record <thread> <foreground|background> | stop <thread> <cap|divergence> | check <thread>" >&2
  exit 1
}

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

field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1; }
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
timestamp() { date -u +%FT%TZ; }
head_sha() { git rev-parse --verify HEAD 2>/dev/null; }
tree_sha() { git rev-parse --verify 'HEAD^{tree}' 2>/dev/null; }
fingerprint() { bash "$FP_HELPER"; }
round_now() {
  _r="$(cat "$STATE_DIR/$THREAD.rounds" 2>/dev/null | tr -cd '0-9')"
  printf '%s' "${_r:-0}"
}
clean_candidate() {
  # Legacy state is metadata, not candidate code. Shared state already lives
  # under the common Git directory and is therefore absent from git status.
  _tracked="$(git ls-files -- '.claude/codex-threads' 2>/dev/null || printf '__inspection_failed__\n')"
  [ -z "$_tracked" ] || return 1
  _dirty="$(git status --porcelain -uall --ignore-submodules=none 2>/dev/null \
    | grep -vE '^.. \.claude/codex-threads(/|$)' || true)"
  [ -z "$_dirty" ]
}
strict_required_verdict() {
  awk '
    /^REPLY:/ { reply=1; next }
    /^(PROMPT:|---$)/ { reply=0; next }
    !reply { next }
    {
      raw=$0
      sub(/^[[:space:]]+/, "", raw)
      if (raw == "") next
      if (raw ~ /^(```+|~~~+)/) { fence = !fence; next }
      if (fence) { last="OTHER"; next }
      if (raw ~ /^([*+-]|>)[[:space:]]/) { last="OTHER"; next }
      line=raw
      sub(/^[[:space:]*_#`]+/, "", line)
      sub(/[-.:;!,*_`[:space:]]+$/, "", line)
      sub(/^[Vv][Ee][Rr][Dd][Ii][Cc][Tt][[:space:]]*:[[:space:]]*/, "", line)
      sub(/^[[:space:]*_`]+/, "", line)
      last=line
      if (line == "APPROVE" || line == "REQUEST_CHANGES") { verdict=line; count++ }
    }
    END { if (count == 1 && last == verdict) print verdict; else exit 1 }
  ' "$1"
}
scope_line_once() {
  _expected="$1"
  _count="$(printf '%s\n' "$PROMPT_SCOPE" | sed 's/^[[:space:]]*//' \
    | grep -Fxc -- "$_expected" || true)"
  [ "${_count:-0}" -eq 1 ]
}
write_state() { # status verdict eligible mode head tree fp round reason
  _base="$(field "$CANDIDATE" base_sha)"; _spec="$(field "$CANDIDATE" spec_path)"
  _cap="$(field "$CANDIDATE" cap)"; _start="$(field "$CANDIDATE" loop_start_round)"
  printf 'version=1\nstatus=%s\nverdict=%s\ngate_eligible=%s\nmode=%s\nhead=%s\ntree=%s\nfingerprint=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nloop_start_round=%s\nround=%s\nreason=%s\ntimestamp=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$_base" "$_spec" "$_cap" "$_start" "$8" "$9" "$(timestamp)" \
    | atomic_write "$REVIEW_STATE"
}

assert_state_files_safe

case "$VERB" in
  begin)
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
    FP="$(fingerprint)"; [ -n "$FP" ] || { echo "cannot fingerprint candidate" >&2; exit 13; }
    CURRENT_ROUND="$(round_now)"
    LAST_STATUS="$(field "$REVIEW_STATE" status)"
    if [ -f "$LOOP_STATE" ] \
      && { [ "$LAST_STATUS" = PENDING ] || [ "$LAST_STATUS" = REQUEST_CHANGES ] || [ "$LAST_STATUS" = NO_DECISION ] || [ "$LAST_STATUS" = STALE ]; } \
      && [ "$(field "$LOOP_STATE" base_sha)" = "$BASE_SHA" ] \
      && [ "$(field "$LOOP_STATE" spec_path)" = "$SPEC_PATH" ] \
      && [ "$(field "$LOOP_STATE" cap)" = "$CAP" ]; then
      LOOP_START="$(field "$LOOP_STATE" start_round)"
    else
      LOOP_START="$CURRENT_ROUND"
      printf 'version=1\nbase_sha=%s\nspec_path=%s\ncap=%s\nstart_round=%s\ntimestamp=%s\n' \
        "$BASE_SHA" "$SPEC_PATH" "$CAP" "$LOOP_START" "$(timestamp)" \
        | atomic_write "$LOOP_STATE" || exit 1
    fi
    case "$LOOP_START" in ''|*[!0-9]*) echo "invalid required review loop state" >&2; exit 1 ;; esac
    [ "$CURRENT_ROUND" -ge "$LOOP_START" ] || { echo "required review round counter moved backwards" >&2; exit 1; }
    if [ $((CURRENT_ROUND - LOOP_START)) -ge "$CAP" ]; then
      echo "CAP_REACHED: required review already spent $CAP round(s)" >&2
      exit 10
    fi
    LOG_BYTES="$(wc -c 2>/dev/null < "$STATE_DIR/$THREAD.log" | tr -d ' ')"; LOG_BYTES="${LOG_BYTES:-0}"
    LOG_GEN="$(cat "$STATE_DIR/$THREAD.log-gen" 2>/dev/null | tr -cd '0-9')"; LOG_GEN="${LOG_GEN:-0}"
    printf 'version=1\nhead=%s\ntree=%s\nfingerprint=%s\nbase_sha=%s\nspec_path=%s\ncap=%s\nloop_start_round=%s\nlog_bytes=%s\nlog_gen=%s\ntimestamp=%s\n' \
      "$HEAD_SHA" "$TREE_SHA" "$FP" "$BASE_SHA" "$SPEC_PATH" "$CAP" "$LOOP_START" "$LOG_BYTES" "$LOG_GEN" "$(timestamp)" \
      | atomic_write "$CANDIDATE" || exit 1
    write_state PENDING NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$FP" "$(round_now)" awaiting_verdict || exit 1
    echo "PENDING head=$HEAD_SHA tree=$TREE_SHA fingerprint=$FP"
    ;;

  record)
    [ $# -eq 3 ] || usage
    MODE="$3"; case "$MODE" in foreground|background) ;; *) usage ;; esac
    LOG="$STATE_DIR/$THREAD.log"
    OFF=0
    if [ -f "$CANDIDATE" ]; then
      OFF="$(field "$CANDIDATE" log_bytes)"; OFF="${OFF:-0}"
      OLD_GEN="$(field "$CANDIDATE" log_gen)"; OLD_GEN="${OLD_GEN:-0}"
      NOW_GEN="$(cat "$STATE_DIR/$THREAD.log-gen" 2>/dev/null | tr -cd '0-9')"; NOW_GEN="${NOW_GEN:-0}"
      [ "$OLD_GEN" = "$NOW_GEN" ] || OFF=0
    fi
    RECORD_TMP="$(mktemp "$STATE_DIR/$THREAD.review-record.XXXXXX")" || exit 1
    trap 'rm -f "$RECORD_TMP" 2>/dev/null' EXIT
    # Judge only the latest dispatch after the candidate cut. Otherwise a later
    # verdict-less/advisory pass could inherit an earlier required APPROVE and
    # its scope markers from the same post-cut window.
    tail -c "+$(( OFF + 1 ))" "$LOG" 2>/dev/null | awk '
      /^\[/ { record=$0 ORS; seen=1; next }
      seen { record=record $0 ORS }
      END { printf "%s", record }
    ' > "$RECORD_TMP"
    VERDICT="$(strict_required_verdict "$RECORD_TMP" 2>/dev/null)"; VRC=$?
    [ "$VRC" -eq 0 ] || VERDICT=NONE
    REVIEW_FP="$(bash "$VERDICT_HELPER" "$RECORD_TMP" 0 --fp 2>/dev/null)"; FRC=$?
    [ "$FRC" -eq 0 ] || REVIEW_FP=""
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"
    FP="$(fingerprint)"

    if [ "$MODE" = background ]; then
      write_state BACKGROUND_SINGLE_PASS "$VERDICT" false background "$HEAD_SHA" "$TREE_SHA" "$REVIEW_FP" "$(round_now)" background_never_satisfies_gate || exit 1
      echo "BACKGROUND_SINGLE_PASS verdict=$VERDICT gate_eligible=false"
      exit 0
    fi

    [ -f "$CANDIDATE" ] || {
      write_state OBSERVED "$VERDICT" false foreground "$HEAD_SHA" "$TREE_SHA" "$REVIEW_FP" "$(round_now)" no_required_candidate || exit 1
      echo "OBSERVED verdict=$VERDICT gate_eligible=false"
      exit 0
    }
    C_HEAD="$(field "$CANDIDATE" head)"; C_TREE="$(field "$CANDIDATE" tree)"; C_FP="$(field "$CANDIDATE" fingerprint)"
    C_BASE="$(field "$CANDIDATE" base_sha)"; C_SPEC="$(field "$CANDIDATE" spec_path)"
    C_CAP="$(field "$CANDIDATE" cap)"; LOOP_START="$(field "$CANDIDATE" loop_start_round)"; CURRENT_ROUND="$(round_now)"
    PROMPT_SCOPE="$(awk '
      /^PROMPT:/ { in_prompt=1; next }
      /^REPLY:/  { in_prompt=0 }
      in_prompt  { print }
    ' "$RECORD_TMP")"
    case "$C_CAP" in 1|2|3|4|5) CAP_VALID=true ;; *) CAP_VALID=false ;; esac
    case "$LOOP_START" in ''|*[!0-9]*) START_VALID=false ;; *) START_VALID=true ;; esac
    if ! $CAP_VALID || ! $START_VALID || ! clean_candidate || [ -z "$FP" ] || [ -z "$C_BASE" ] || [ -z "$C_SPEC" ] \
      || [ "$HEAD_SHA" != "$C_HEAD" ] || [ "$TREE_SHA" != "$C_TREE" ] || [ "$FP" != "$C_FP" ] || [ "$REVIEW_FP" != "$C_FP" ] \
      || ! scope_line_once 'REQUIRED_REVIEW' \
      || ! scope_line_once "BASE_SHA: $C_BASE" \
      || ! scope_line_once "CANDIDATE_SHA: $C_HEAD" \
      || ! scope_line_once "SPEC_PATH: $C_SPEC"; then
      write_state STALE "$VERDICT" false foreground "$HEAD_SHA" "$TREE_SHA" "${REVIEW_FP:-unknown}" "$(round_now)" candidate_moved_or_unattributable || exit 1
      echo "STALE: verdict does not cover the current clean candidate" >&2
      exit 11
    fi
    case "$VERDICT" in
      APPROVE)
        write_state APPROVED APPROVE true foreground "$C_HEAD" "$C_TREE" "$C_FP" "$(round_now)" exact_candidate_approved || exit 1
        atomic_write "$APPROVED" < "$REVIEW_STATE" || exit 1
        echo "APPROVE head=$C_HEAD tree=$C_TREE fingerprint=$C_FP"
        ;;
      REQUEST_CHANGES)
        if [ -n "$C_CAP" ] && [ -n "$LOOP_START" ] && [ $((CURRENT_ROUND - LOOP_START)) -ge "$C_CAP" ]; then
          write_state CAP_REACHED REQUEST_CHANGES false foreground "$C_HEAD" "$C_TREE" "$C_FP" "$CURRENT_ROUND" cap || exit 1
          echo "CAP_REACHED: blocking findings remain after $C_CAP round(s)" >&2
          exit 10
        fi
        write_state REQUEST_CHANGES REQUEST_CHANGES false foreground "$C_HEAD" "$C_TREE" "$C_FP" "$(round_now)" blocking_findings_open || exit 1
        echo "REQUEST_CHANGES: fix, test, commit a new candidate, then begin and review again" >&2
        exit 10
        ;;
      *)
        if [ $((CURRENT_ROUND - LOOP_START)) -ge "$C_CAP" ]; then
          write_state CAP_REACHED "$VERDICT" false foreground "$C_HEAD" "$C_TREE" "$C_FP" "$CURRENT_ROUND" cap || exit 1
          echo "CAP_REACHED: no approval after $C_CAP round(s)" >&2
          exit 10
        fi
        write_state NO_DECISION "$VERDICT" false foreground "$C_HEAD" "$C_TREE" "$C_FP" "$(round_now)" no_approve_verdict || exit 1
        echo "NO_DECISION: required review did not return APPROVE" >&2
        exit 10
        ;;
    esac
    ;;

  stop)
    [ $# -eq 3 ] || usage
    REASON="$3"; case "$REASON" in cap) STATUS=CAP_REACHED ;; divergence) STATUS=DIVERGED ;; *) usage ;; esac
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"; FP="$(fingerprint)"
    write_state "$STATUS" NONE false foreground "$HEAD_SHA" "$TREE_SHA" "$FP" "$(round_now)" "$REASON" || exit 1
    echo "$STATUS: hard stop; no gate approval was produced" >&2
    exit 10
    ;;

  check)
    [ $# -eq 2 ] || usage
    [ -f "$REVIEW_STATE" ] && [ -f "$APPROVED" ] || { echo "NO_APPROVAL" >&2; exit 10; }
    [ "$(field "$REVIEW_STATE" status)" = APPROVED ] \
      && [ "$(field "$REVIEW_STATE" gate_eligible)" = true ] \
      && [ "$(field "$APPROVED" verdict)" = APPROVE ] \
      && [ "$(field "$APPROVED" mode)" = foreground ] \
      && [ -n "$(field "$APPROVED" base_sha)" ] \
      && [ -n "$(field "$APPROVED" spec_path)" ] \
      || { echo "NO_APPROVAL" >&2; exit 10; }
    clean_candidate || { echo "STALE: candidate is dirty" >&2; exit 11; }
    HEAD_SHA="$(head_sha 2>/dev/null || true)"; TREE_SHA="$(tree_sha 2>/dev/null || true)"; FP="$(fingerprint)"
    [ "$HEAD_SHA" = "$(field "$APPROVED" head)" ] \
      && [ "$TREE_SHA" = "$(field "$APPROVED" tree)" ] \
      && [ "$FP" = "$(field "$APPROVED" fingerprint)" ] \
      || { echo "STALE: approval belongs to another candidate" >&2; exit 11; }
    echo "CC_CODEX_REQUIRED_REVIEW APPROVE thread=$THREAD head=$HEAD_SHA tree=$TREE_SHA fingerprint=$FP base_sha=$(field "$APPROVED" base_sha) spec_path=$(field "$APPROVED" spec_path)"
    ;;
  *) usage ;;
esac
