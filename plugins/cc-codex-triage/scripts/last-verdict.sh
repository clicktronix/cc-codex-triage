#!/usr/bin/env bash
# cc-codex-triage — last machine-readable verdict in a thread log.
#
# usage: last-verdict.sh <log-file> [byte-offset] [--fp|--fp-plan-latest]
#
# Prints APPROVE | REQUEST_CHANGES | COMMENT, or nothing. Shared by the Stop
# hook and /status — two copies disagreeing would mean /status reporting an
# APPROVE the gate refuses.
#
# THE FINGERPRINT RULE (authoritative; callers just obey the answer).
# --fp prints the code fingerprint of the record that CONTAINED the selected
# verdict, from the `fp=` field the driver stamps into that record's header.
# Selecting verdict and fingerprint independently was a hole: an APPROVE for
# state A followed by a verdict-less dispatch B released B, because the
# fingerprint came from a sidecar B had overwritten.
#   - record predating `fp=`, and it is the LATEST record  -> exit 1, and the
#     caller may fall back to the sidecar (it still describes that dispatch);
#   - record predating `fp=` with a LATER record behind it -> exit 2. The
#     sidecar now describes that later dispatch, so the pair is unknowable, and
#     callers must NOT release: substituting any fingerprint there is the same
#     hole in legacy clothing.
#
# EXIT: 0 a value was printed; 1 nothing to report; 2 cannot be attributed. A
# status, not a reserved word on stdout — one channel carrying both the payload
# and its own failure mode is what made every caller string-compare a hash.
# --fp-plan-latest ignores verdicts and returns the plan fingerprint of the LAST
# post-cut record: the plan gate releases on log GROWTH, so its releasing
# dispatch is the most recent one, verdict or not.
#
# Section tracking: the driver writes column-0 markers and indents body lines,
# so a verdict quoted inside a PROMPT cannot release the gate. `tail -c` may
# start mid-section, so lines are ignored until a column-0 REPLY: is seen —
# that blocks toward the cap, never falsely releases.
#
# The offset is the cycle's cut: only content after it is parsed, so the verdict
# that released the previous cycle cannot release this one. A log SMALLER than
# the offset was rotated or reset, so all of it is post-cut.
#
# Matching normalizes, then compares EXACTLY: Codex writes `## APPROVE` and
# `**APPROVE**`, which the old strict pattern missed, but "not quite APPROVE"
# must still not reduce to the token.
set -u
LOG="${1:?usage: last-verdict.sh <log-file> [byte-offset] [--fp|--fp-plan-latest]}"
OFF="${2:-0}"
WANT="verdict"
case "${3:-}" in
  --fp)             WANT=fp ;;
  --fp-plan-latest) WANT=fpplanlatest ;;
esac
[ -f "$LOG" ] || exit 1
case "$OFF" in ''|*[!0-9]*) OFF=0 ;; esac

SIZE="$(wc -c 2>/dev/null < "$LOG" | tr -d ' ')"
case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
[ "$SIZE" -lt "$OFF" ] && OFF=0

tail -c +"$(( OFF + 1 ))" "$LOG" 2>/dev/null | awk -v want="$WANT" '
  # A record header carries the state this dispatch was made against. `tail -c`
  # can start mid-file, so a record whose header was cut off simply has none.
  /^\[/ {
    r = 0; cur_fp = ""; cur_fpplan = ""
    rec++                                  # records seen after the cut, in order
    if (match($0, /[ ]fp=[0-9a-f]+/))      cur_fp     = substr($0, RSTART+4, RLENGTH-4)
    if (match($0, /[ ]fp-plan=[0-9a-f]+/)) cur_fpplan = substr($0, RSTART+9, RLENGTH-9)
    last_fpplan = cur_fpplan               # the plan gate releases on the LAST dispatch
    next
  }
  /^REPLY:/            { r = 1; next }
  /^(PROMPT:|---$)/    { r = 0; next }
  r {
    # Trim from the ENDS only: a global strip of "_" turns REQUEST_CHANGES into
    # REQUESTCHANGES and silently stops every change request being seen.
    line = $0
    sub(/^[[:space:]*_#`>-]+/, "", line)      # headings, emphasis, bullets, quotes, indent
    sub(/[-.:;!,*_`[:space:]]+$/, "", line)   # punctuation, plus the --- reply terminator
    # Spelled per character: awk has no portable case-insensitive flag.
    sub(/^[Vv][Ee][Rr][Dd][Ii][Cc][Tt][[:space:]]*:[[:space:]]*/, "", line)
    sub(/^[[:space:]*_`>]+/, "", line)
    if (line == "APPROVE" || line == "REQUEST_CHANGES" || line == "COMMENT") {
      v = line; v_fp = cur_fp; v_rec = rec
    }
  }
  END {
    # The latest-record lookup is verdict-independent by design.
    if (want == "fpplanlatest") { if (last_fpplan == "") exit 1; print last_fpplan; exit 0 }
    if (v == "") exit 1
    if (want == "fp") {
      if (v_fp != "") { print v_fp; exit 0 }
      if (rec > v_rec) exit 2      # a later record owns the sidecar now
      exit 1
    }
    print v; exit 0
  }
'
