#!/usr/bin/env bash
# Parse a verdict from a cc-codex-triage log record.
#
# usage:
#   verdict.sh strict <record-file>
#   verdict.sh informational <log-file> [byte-offset]
#
# `strict` is the delivery-gate policy: exactly one bare APPROVE or
# REQUEST_CHANGES in REPLY, and it must be the final reply line.
# `informational` is display-only: it accepts Markdown decoration and COMMENT
# and returns the last recognizable verdict. It must never authorize delivery.
set -u

MODE="${1:-}"
FILE="${2:-}"
[ -n "$MODE" ] && [ -n "$FILE" ] \
  || { echo "usage: verdict.sh strict <record-file> | informational <log-file> [byte-offset]" >&2; exit 1; }
[ -f "$FILE" ] || exit 1

case "$MODE" in
  strict)
    [ "$#" -eq 2 ] || exit 1
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
    ;;
  informational)
    [ "$#" -le 3 ] || exit 1
    OFF="${3:-0}"
    case "$OFF" in ''|*[!0-9]*) OFF=0 ;; esac
    SIZE="$(wc -c 2>/dev/null < "$FILE" | tr -d ' ')"
    case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
    [ "$SIZE" -lt "$OFF" ] && OFF=0
    tail -c "+$((OFF + 1))" "$FILE" 2>/dev/null | awk '
      /^REPLY:/ { reply=1; next }
      /^(PROMPT:|---$)/ { reply=0; next }
      !reply { next }
      {
        line=$0
        if (line ~ /^[[:space:]]*[*+-][[:space:]]/) next
        sub(/^[[:space:]*_#`]+/, "", line)
        sub(/[-.:;!,*_`[:space:]]+$/, "", line)
        sub(/^[Vv][Ee][Rr][Dd][Ii][Cc][Tt][[:space:]]*:[[:space:]]*/, "", line)
        sub(/^[[:space:]*_`]+/, "", line)
        if (line == "APPROVE" || line == "REQUEST_CHANGES" || line == "COMMENT") verdict=line
      }
      END { if (verdict == "") exit 1; print verdict }
    '
    ;;
  *) echo "unknown verdict mode: $MODE" >&2; exit 1 ;;
esac
