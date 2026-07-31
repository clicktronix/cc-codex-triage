#!/usr/bin/env bash
# cc-codex-triage — last machine-readable verdict in a thread log.
#
# usage: last-verdict.sh <log-file> [byte-offset]
#
# Prints APPROVE | REQUEST_CHANGES | COMMENT, or nothing. One implementation,
# two callers — the Stop hook (which decides whether a turn may end) and
# /status (which reports the same fact to a human). They disagreeing would mean
# /status telling you the gate should have released while the gate blocks.
#
# Two protections, both load-bearing:
#
#   Section tracking. The driver writes column-0 markers (PROMPT: / REPLY: /
#   --- / [timestamp]) and indents body lines by two spaces, so a verdict
#   literal inside a logged PROMPT — a /reply quoting "earlier you said
#   APPROVE" — can never release the gate. `tail -c` may start mid-line or
#   mid-section: until a column-0 REPLY: marker is seen, lines are ignored.
#   That blocks toward the cap, never toward a false release.
#
#   The byte offset. Only content appended after the current cycle's cut is
#   parsed, so the APPROVE that released the previous cycle cannot release this
#   one. A log SMALLER than the offset was rotated or reset, and everything
#   left is post-cut, so the whole file is parsed.
#
# Matching normalizes, then compares exactly. The contract asks for a verdict
# alone on its own line, but Codex legitimately writes `## APPROVE`,
# `**APPROVE**` and `Verdict: APPROVE.` — a production thread went five rounds
# where NOT ONE reply matched the old strict pattern, so the gate could never
# release and burned its whole cap on an approved branch. Stripping emphasis
# and heading marks before an EXACT comparison accepts those forms while still
# refusing every line that carries other words: "not quite APPROVE" and "I
# would not give APPROVE here" do not reduce to the bare token, so they cannot
# release anything.
set -u
LOG="${1:?usage: last-verdict.sh <log-file> [byte-offset]}"
OFF="${2:-0}"
[ -f "$LOG" ] || exit 0
case "$OFF" in ''|*[!0-9]*) OFF=0 ;; esac

SIZE="$(wc -c 2>/dev/null < "$LOG" | tr -d ' ')"
case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
[ "$SIZE" -lt "$OFF" ] && OFF=0

tail -c +"$(( OFF + 1 ))" "$LOG" 2>/dev/null | awk '
  /^REPLY:/            { r = 1; next }
  /^(PROMPT:|---$|\[)/ { r = 0; next }
  r {
    # Trim from the ENDS only — never a global strip. A global gsub of "_"
    # turns REQUEST_CHANGES into REQUESTCHANGES and silently stops every
    # change request from being seen.
    line = $0
    sub(/^[[:space:]*_#`]+/, "", line)             # heading marks, emphasis, indent
    sub(/[-.:;!,*_`[:space:]]+$/, "", line)        # trailing punctuation, plus the --- reply terminator
    sub(/^[Vv]erdict[[:space:]]*:[[:space:]]*/, "", line)
    sub(/^[[:space:]*_`]+/, "", line)              # emphasis that opened after "Verdict:"
    if (line == "APPROVE" || line == "REQUEST_CHANGES" || line == "COMMENT") v = line
  }
  END { if (v != "") print v }
'
