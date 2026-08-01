#!/usr/bin/env bash
# cc-codex-triage — last machine-readable verdict in a thread log.
#
# usage: last-verdict.sh <log-file> [byte-offset] [--fp|--fp-plan|--fp-plan-latest]
#
# Prints APPROVE | REQUEST_CHANGES | COMMENT, or nothing. Shared by the Stop
# hook and /status — two copies disagreeing would mean /status reporting an
# APPROVE the gate refuses, which reads as the gate being broken.
#
# --fp / --fp-plan print instead the code fingerprint of the RECORD THAT
# CONTAINED THE SELECTED VERDICT, taken from the `fp=` / `fp-plan=` fields the
# driver stamps into that record's header. Selecting the verdict and the
# fingerprint independently was a real hole: an APPROVE for state A followed by
# a successful but verdict-less dispatch B released B, because the verdict came
# from the log while the fingerprint came from a mutable sidecar that B had
# overwritten.
#
# A record written before headers carried these fields yields nothing, and the
# caller falls back to the sidecar — correct as long as that record is the
# LATEST one, which is the ordinary legacy case. When a later record exists the
# sidecar describes that later dispatch instead, so the pairing is unknowable
# and the answer is the literal `AMBIGUOUS`. Callers must not release on it:
# substituting any fingerprint there is the original hole in legacy clothing.
#
# --fp-plan-latest ignores verdicts entirely and returns the plan fingerprint of
# the LAST post-cut record. The plan gate releases on log GROWTH, not on a
# verdict, so the dispatch that releases it is the most recent one — asking for
# the verdict's record there released an older state and re-blocked the current
# one.
#
# Section tracking: the driver writes column-0 markers and indents body lines,
# so a verdict quoted inside a PROMPT (a /reply saying "earlier you said
# APPROVE") cannot release the gate. `tail -c` may start mid-section, so lines
# are ignored until a column-0 REPLY: marker is seen — that blocks toward the
# cap, never falsely releases.
#
# The offset is the cycle's cut: only content appended after it is parsed, so
# the verdict that released the previous cycle cannot release this one. A log
# SMALLER than the offset was rotated or reset, so all of it is post-cut.
#
# Matching normalizes, then compares EXACTLY. The contract asks for a bare
# verdict line, but Codex writes `## APPROVE` and `**APPROVE**` — one production
# thread went five rounds with none matching the old strict pattern, so an
# approved branch could never release the gate. Trimming decoration and then
# demanding equality accepts those forms while still refusing every line
# carrying other words: "not quite APPROVE" does not reduce to the token.
set -u
LOG="${1:?usage: last-verdict.sh <log-file> [byte-offset] [--fp|--fp-plan|--fp-plan-latest]}"
OFF="${2:-0}"
WANT="verdict"
case "${3:-}" in
  --fp)             WANT=fp ;;
  --fp-plan)        WANT=fpplan ;;
  --fp-plan-latest) WANT=fpplanlatest ;;
esac
[ -f "$LOG" ] || exit 0
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
      v = line; v_fp = cur_fp; v_fpplan = cur_fpplan; v_rec = rec
    }
  }
  END {
    # The latest-record lookup is verdict-independent by design.
    if (want == "fpplanlatest") { if (last_fpplan != "") print last_fpplan; exit }
    if (v == "") exit
    if (want == "fp" || want == "fpplan") {
      f = (want == "fp") ? v_fp : v_fpplan
      if (f != "") { print f; exit }
      # No marker on the record that carried the verdict. Falling back to the
      # sidecar is safe only while that record is still the last one; once a
      # later dispatch has overwritten it, the pair cannot be reconstructed.
      # (No apostrophes in here: this awk program is single-quoted, and one
      # closed it mid-comment — the whole script stopped parsing.)
      if (rec > v_rec) print "AMBIGUOUS"
      exit
    }
    print v
  }
'
