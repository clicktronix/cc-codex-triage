#!/usr/bin/env bash
# Parse a verdict from a cc-codex-triage log record.
#
# usage: verdict.sh <record-file>
#
# The delivery-gate policy accepts exactly one bare APPROVE or REQUEST_CHANGES
# in REPLY, and it must be the final reply line.
set -u

FILE="${1:-}"
[ "$#" -eq 1 ] && [ -n "$FILE" ] \
  || { echo "usage: verdict.sh <record-file>" >&2; exit 1; }
[ -f "$FILE" ] || exit 1

awk '
  /^REPLY:/ { reply=1; next }
  /^(PROMPT:|---$)/ { reply=0; next }
  !reply { next }
  {
    if (substr($0, 1, 2) != "  ") { last="OTHER"; next }
    line=substr($0, 3)
    if (line == "") next

    probe=line; spaces=0
    while (substr(probe, 1, 1) == " " && spaces < 4) {
      probe=substr(probe, 2); spaces++
    }
    marker=substr(probe, 1, 1); marker_len=0
    if (spaces <= 3 && (marker == "`" || marker == "~")) {
      while (substr(probe, marker_len + 1, 1) == marker) marker_len++
    }
    if (marker_len >= 3) {
      last="OTHER"; rest=substr(probe, marker_len + 1)
      if (fence_char == "") {
        if (!(marker == "`" && index(rest, "`") > 0)) {
          fence_char=marker; fence_len=marker_len
        }
      } else if (marker == fence_char && marker_len >= fence_len && rest ~ /^[ ]*$/) {
        fence_char=""; fence_len=0
      }
      next
    }
    if (fence_char != "") { last="OTHER"; next }
    last=line
    if (line == "APPROVE" || line == "REQUEST_CHANGES") {
      verdict=line; count++
    }
  }
  END {
    if (fence_char == "" && count == 1 && last == verdict) print verdict
    else exit 1
  }
' "$FILE"
