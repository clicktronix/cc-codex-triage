#!/usr/bin/env bash
# cc-codex-triage — findings ledger for /review.
#
# Event-sourced JSONL at .claude/codex-threads/<thread>.findings.jsonl: one JSON
# object per line, either a "create" event (a new finding, status=open) or a
# "status" event (a status change for an existing id). Current state of a
# finding = its create event folded with its LAST status event.
#
# IDs are allocated HERE (f1, f2, ...) — never by the caller — so they stay
# unique and stable across rounds; a later round references the existing id when
# it resolves/disputes a finding (no fragile re-matching of reworded findings).
# The user-visible summary should be rendered from `ledger.sh list`, so what the
# user sees is exactly what was recorded.
#
# Requires jq. If jq is absent the ledger is disabled; the core review still works.
#
# Subcommands:
#   create <thread> --file F --line L --severity blocking|non-blocking --label L --title "T"   -> prints the new id
#   status <thread> <id> <open|resolved|false-positive|accepted|deferred> [--note "T"]
#   open   <thread>     -> open findings, one per line
#   list   <thread>     -> all findings (folded), one per line
#   get    <thread> <id>-> the folded JSON record for one id

set -u

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" 2>/dev/null || true
STATE_DIR=".claude/codex-threads"

command -v jq >/dev/null 2>&1 || { echo "ledger: jq is required (brew install jq / apt-get install jq)" >&2; exit 2; }

usage() { echo "usage: ledger.sh create|status|open|list|get <thread> [...]" >&2; exit 1; }

SUB="${1:-}"; THREAD="${2:-}"
[ -n "$SUB" ] && [ -n "$THREAD" ] || usage
[[ "$THREAD" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "ledger: thread name must be [a-zA-Z0-9_.-]+" >&2; exit 1; }
shift 2
F="$STATE_DIR/$THREAD.findings.jsonl"
ts() { date -u +%FT%TZ; }

# Fold the event log into one folded record per id (create fields + last status).
fold() {
  [ -f "$F" ] || { echo '[]'; return; }
  jq -s '
    (map(select(.event=="create")) | group_by(.id) | map(.[-1])) as $creates
    | (map(select(.event=="status")) | group_by(.id)
       | map({key:.[0].id, value:(.[-1])}) | from_entries)        as $last
    | [ $creates[] | . + {status:($last[.id].status // .status),
                          note:($last[.id].note // null)} ]
  ' "$F"
}

case "$SUB" in
  create)
    file=""; line=""; sev=""; label="issue"; title=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --file|--line|--severity|--label|--title)
          # Require a value — otherwise `shift 2` on a trailing flag would not
          # advance and the loop would spin forever.
          [ $# -ge 2 ] || { echo "ledger create: $1 needs a value" >&2; exit 1; }
          case "$1" in
            --file) file="$2" ;; --line) line="$2" ;; --severity) sev="$2" ;;
            --label) label="$2" ;; --title) title="$2" ;;
          esac
          shift 2 ;;
        *) echo "ledger create: unknown arg '$1'" >&2; exit 1 ;;
      esac
    done
    [ -n "$title" ] || { echo "ledger create: --title is required" >&2; exit 1; }
    case "$sev" in blocking|non-blocking) ;; *) echo "ledger create: --severity must be blocking|non-blocking" >&2; exit 1 ;; esac
    # Keep .line a non-negative integer or null — reject non-numeric/negative/float.
    case "$line" in ''|*[!0-9]*) line="" ;; esac
    mkdir -p "$STATE_DIR"
    # next id = max existing fN + 1 (create events only)
    maxn=0
    if [ -f "$F" ]; then
      maxn="$(jq -r 'select(.event=="create").id' "$F" 2>/dev/null | sed -n 's/^f//p' | sort -n | tail -1)"
      case "${maxn:-}" in ''|*[!0-9]*) maxn=0 ;; esac
    fi
    id="f$((maxn + 1))"
    jq -cn --arg id "$id" --arg ts "$(ts)" --arg file "$file" --arg line "$line" \
           --arg sev "$sev" --arg label "$label" --arg title "$title" \
       '{event:"create",id:$id,ts:$ts,file:$file,
         line:($line|if .=="" then null else (tonumber? // .) end),
         severity:$sev,label:$label,title:$title,status:"open"}' >> "$F"
    echo "$id"
    ;;
  status)
    id="${1:-}"; newst="${2:-}"; note=""
    [ -n "$id" ] && [ -n "$newst" ] || { echo "ledger status: <id> <status> required" >&2; exit 1; }
    shift 2 2>/dev/null || true
    [ "${1:-}" = "--note" ] && note="${2:-}"
    case "$newst" in open|resolved|false-positive|accepted|deferred) ;; *) echo "ledger status: status must be open|resolved|false-positive|accepted|deferred" >&2; exit 1 ;; esac
    { [ -f "$F" ] && jq -e --arg id "$id" 'select(.event=="create" and .id==$id)' "$F" >/dev/null 2>&1; } \
      || { echo "ledger status: unknown id '$id' (no create event)" >&2; exit 1; }
    jq -cn --arg id "$id" --arg ts "$(ts)" --arg st "$newst" --arg note "$note" \
       '{event:"status",id:$id,ts:$ts,status:$st,note:($note|if .=="" then null else . end)}' >> "$F"
    ;;
  open)
    fold | jq -r '.[] | select(.status=="open") | "\(.id)  [\(.severity)] \(.status)  \(.file // "?"):\(.line // "?")  \(.title)"'
    ;;
  list)
    fold | jq -r '.[] | "\(.id)  [\(.severity)] \(.status)  \(.file // "?"):\(.line // "?")  \(.title)"'
    ;;
  get)
    id="${1:-}"; [ -n "$id" ] || { echo "ledger get: <id> required" >&2; exit 1; }
    fold | jq -e --arg id "$id" '.[] | select(.id==$id)' || { echo "ledger get: unknown id '$id'" >&2; exit 1; }
    ;;
  *) usage ;;
esac
