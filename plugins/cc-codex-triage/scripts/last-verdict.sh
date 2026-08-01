#!/usr/bin/env bash
# cc-codex-triage — last machine-readable verdict in a thread log.
#
# usage: last-verdict.sh <log-file> [byte-offset] [--fp|--fp-plan]
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
# overwritten. Records written before the header carried these fields yield
# nothing, and the caller keeps its previous fallback.
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
LOG="${1:?usage: last-verdict.sh <log-file> [byte-offset] [--fp|--fp-plan]}"
OFF="${2:-0}"
WANT="verdict"
case "${3:-}" in --fp) WANT=fp ;; --fp-plan) WANT=fpplan ;; esac
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
    if (match($0, /[ ]fp=[0-9a-f]+/))      cur_fp     = substr($0, RSTART+4, RLENGTH-4)
    if (match($0, /[ ]fp-plan=[0-9a-f]+/)) cur_fpplan = substr($0, RSTART+9, RLENGTH-9)
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
      v = line; v_fp = cur_fp; v_fpplan = cur_fpplan
    }
  }
  END {
    if (v == "") exit
    if      (want == "fp")     { if (v_fp != "")     print v_fp }
    else if (want == "fpplan") { if (v_fpplan != "") print v_fpplan }
    else                         print v
  }
'
