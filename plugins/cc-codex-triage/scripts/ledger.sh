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
#   create <thread> --file F --line L --severity blocking|non-blocking --label L --title "T" [--confidence 0..1]   -> prints the new id
#   status <thread> <id> <open|resolved|false-positive|accepted|deferred> [--note "T"]
#   open   <thread>     -> open findings, one per line
#   list   <thread>     -> all findings (folded), one per line
#   get    <thread> <id>-> the folded JSON record for one id

set -u

# Anchor to the RESOLVED repo root (mirrors the driver's rule): a
# CLAUDE_PROJECT_DIR naming a repo SUBDIR resolves UP — state always lives at
# the repo ROOT. HARD-FAIL outside a repo (exit 7, driver parity): `create`
# WRITES the findings ledger, and a fail-soft fallback would write it into
# whatever directory the caller happens to sit in.
if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
  echo "ledger.sh must run inside a git repository (thread state lives at the repo root)" >&2
  exit 7
fi
cd "$ROOT" || exit 7
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
# Fails CLOSED on a corrupt/partial JSONL: a swallowed jq parse error would
# otherwise make `open`/`list`/`get` render an unreadable ledger as EMPTY,
# silently hiding findings. On parse failure: nothing on stdout, return 1.
fold() {
  [ -f "$F" ] || { echo '[]'; return 0; }
  jq -s '
    (map(select(.event=="create")) | group_by(.id) | map(.[-1])) as $creates
    | (map(select(.event=="status")) | group_by(.id)
       | map({key:.[0].id, value:(.[-1])}) | from_entries)        as $last
    | [ $creates[] | . + {status:($last[.id].status // .status),
                          note:($last[.id].note // null)} ]
  ' "$F" 2>/dev/null || {
    echo "ledger: $F is not valid JSONL (corrupt or partial write) — refusing to render a partial view" >&2
    return 1
  }
}

# Writers' fail-closed guard: never allocate an id from, or append to, a ledger
# the readers can't render. The max-id scan below tolerates jq errors (no
# pipefail), so a bad line before the valid creates would truncate the scan and
# re-hand-out f1 onto a file fold() then refuses. Reuse fold() itself as the
# validator so the writer guard matches the reader contract EXACTLY — fold fails
# not only on unparseable JSON but on parseable-but-invalid records too (a scalar
# line like `42` parses, yet `.event` can't index it). Abort with exit 3 (same as
# the readers) so the file is repaired before more events pile on.
ensure_parseable() {
  [ -f "$F" ] || return 0
  fold >/dev/null 2>&1 || {
    echo "ledger: $F is not a valid findings ledger (corrupt, partial, or non-event records) — refusing to write; inspect/repair it first." >&2
    exit 3
  }
}

case "$SUB" in
  create)
    file=""; line=""; sev=""; label="issue"; title=""; conf=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --file|--line|--severity|--label|--title|--confidence)
          # Require a value — otherwise `shift 2` on a trailing flag would not
          # advance and the loop would spin forever.
          [ $# -ge 2 ] || { echo "ledger create: $1 needs a value" >&2; exit 1; }
          case "$1" in
            --file) file="$2" ;; --line) line="$2" ;; --severity) sev="$2" ;;
            --label) label="$2" ;; --title) title="$2" ;; --confidence) conf="$2" ;;
          esac
          shift 2 ;;
        *) echo "ledger create: unknown arg '$1'" >&2; exit 1 ;;
      esac
    done
    [ -n "$title" ] || { echo "ledger create: --title is required" >&2; exit 1; }
    [ -n "$file" ] || { echo "ledger create: --file is required (findings need a file:line citation)" >&2; exit 1; }
    case "$sev" in blocking|non-blocking) ;; *) echo "ledger create: --severity must be blocking|non-blocking" >&2; exit 1 ;; esac
    # Keep .line a non-negative integer or null — reject non-numeric/negative/float.
    case "$line" in ''|*[!0-9]*) line="" ;; esac
    # Keep .confidence a number in 0..1 or null — reject non-numeric/garbage and
    # out-of-range values (the schema promises 0..1) rather than writing them.
    case "$conf" in ''|*[!0-9.]*) conf="" ;; esac
    if [ -n "$conf" ] && ! awk -v c="$conf" 'BEGIN{exit !(c>=0 && c<=1)}'; then conf=""; fi
    mkdir -p "$STATE_DIR"
    ensure_parseable   # never allocate an id from / append to a corrupt ledger
    # next id = max existing fN + 1 (create events only)
    maxn=0
    if [ -f "$F" ]; then
      # Only well-formed ids (^f[0-9]+$) feed the max. A malformed id (e.g. f9x
      # from a hand-edit) must not poison allocation: previously one bad id at the
      # numeric top reset maxn to 0 and re-handed-out f1, colliding with an
      # existing finding (which fold() then silently merged). sed emits the
      # numeric suffix ONLY for ids matching the shape; everything else is dropped.
      maxn="$(jq -r 'select(.event=="create").id' "$F" 2>/dev/null | sed -n 's/^f\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)"
      case "${maxn:-}" in ''|*[!0-9]*) maxn=0 ;; esac
    fi
    id="f$((maxn + 1))"
    jq -cn --arg id "$id" --arg ts "$(ts)" --arg file "$file" --arg line "$line" \
           --arg sev "$sev" --arg label "$label" --arg title "$title" --arg conf "$conf" \
       '{event:"create",id:$id,ts:$ts,file:$file,
         line:($line|if .=="" then null else (tonumber? // .) end),
         severity:$sev,label:$label,title:$title,
         confidence:($conf|if .=="" then null else (tonumber? // null) end),
         status:"open"}' >> "$F"
    echo "$id"
    ;;
  status)
    id="${1:-}"; newst="${2:-}"; note=""
    [ -n "$id" ] && [ -n "$newst" ] || { echo "ledger status: <id> <status> required" >&2; exit 1; }
    shift 2 2>/dev/null || true
    [ "${1:-}" = "--note" ] && note="${2:-}"
    case "$newst" in open|resolved|false-positive|accepted|deferred) ;; *) echo "ledger status: status must be open|resolved|false-positive|accepted|deferred" >&2; exit 1 ;; esac
    ensure_parseable   # clear "corrupt ledger" error instead of a misleading "unknown id"
    { [ -f "$F" ] && jq -e --arg id "$id" 'select(.event=="create" and .id==$id)' "$F" >/dev/null 2>&1; } \
      || { echo "ledger status: unknown id '$id' (no create event)" >&2; exit 1; }
    jq -cn --arg id "$id" --arg ts "$(ts)" --arg st "$newst" --arg note "$note" \
       '{event:"status",id:$id,ts:$ts,status:$st,note:($note|if .=="" then null else . end)}' >> "$F"
    ;;
  open)
    # Capture fold separately so its non-zero exit (corrupt ledger) aborts here
    # instead of being swallowed by the pipe, which would print an empty list.
    recs="$(fold)" || exit 3
    printf '%s\n' "$recs" | jq -r '.[] | select(.status=="open") | "\(.id)  [\(.severity)] \(.status)  \(.file // "?"):\(.line // "?")  \(.title)"'
    ;;
  list)
    recs="$(fold)" || exit 3
    printf '%s\n' "$recs" | jq -r '.[] | "\(.id)  [\(.severity)] \(.status)  \(.file // "?"):\(.line // "?")  \(.title)"'
    ;;
  get)
    id="${1:-}"; [ -n "$id" ] || { echo "ledger get: <id> required" >&2; exit 1; }
    recs="$(fold)" || exit 3
    printf '%s\n' "$recs" | jq -e --arg id "$id" '.[] | select(.id==$id)' || { echo "ledger get: unknown id '$id'" >&2; exit 1; }
    ;;
  *) usage ;;
esac
