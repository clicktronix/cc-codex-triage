#!/usr/bin/env bash
# cc-codex-triage — what threads exist in this repo, and what each is about.
#
# usage: thread-index.sh [--tsv | --resolve [known-or-explicit-name]]
#
# Default output is a human table; --tsv is one record per line
# (name, topic, rounds, log bytes, last activity, busy) for a caller that wants
# to pick a thread rather than show one.
#
# Read-only, no Codex dispatch — the model-invocable review workflow may run
# it to reuse the correct task thread.
#
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/lib.sh"
STATE_DIR="$(bash "$SELF_DIR/state-dir.sh" --read-only)" || exit $?
mode="${1:-table}"
names=()
shopt -s dotglob
for path in "$STATE_DIR"/*.id "$STATE_DIR"/*.active; do
  [ -f "$path" ] && [ ! -L "$path" ] || continue
  file="${path##*/}"; name="${file%.*}"
  [ -n "$name" ] || continue
  if [[ "$path" == *.active ]]; then
    [ ! -f "$STATE_DIR/$name.id" ] && live_lease "$path" || continue
  fi
  names+=("$name")
done

if [ "$mode" = --resolve ]; then
  # A failed first launch can leave a required contract without a session UUID.
  for path in "$STATE_DIR"/*.review-loop; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    file="${path##*/}"; name="${file%.review-loop}"
    [ -n "$name" ] && [ ! -f "$STATE_DIR/$name.id" ] || continue
    live_lease "$STATE_DIR/$name.active" || names+=("$name")
  done
  if [ "$#" -gt 1 ]; then
    wanted="$2"
    case "$wanted" in ''|*[!a-zA-Z0-9_.-]*) echo "Invalid thread name" >&2; exit 1 ;; esac
    for name in "${names[@]+"${names[@]}"}"; do
      if [ "$name" = "$wanted" ]; then echo "$name"; exit 0; fi
    done
    echo "No thread named $wanted. Available: ${names[*]:-none}" >&2; exit 6
  fi
  case "${#names[@]}" in
    0) echo "No active threads in this context." >&2; exit 6 ;;
    1) echo "${names[0]}"; exit 0 ;;
    *) echo "Choose a thread: ${names[*]}" >&2; exit 8 ;;
  esac
fi
if [ "${#names[@]}" -eq 0 ]; then [ "$mode" = --tsv ] || echo "No active threads in this context."; exit 0; fi
[ "$mode" = --tsv ] || printf '%-30s  %-7s  %-9s  %-16s  %s\n' THREAD ROUNDS LOG_SIZE LAST_ACTIVITY TOPIC

for name in "${names[@]}"; do
  rounds="$(cat "$STATE_DIR/$name.rounds" 2>/dev/null | tr -cd '0-9')"; rounds="${rounds:-0}"
  logsz="$(wc -c 2>/dev/null < "$STATE_DIR/$name.log" | tr -d ' ')"; logsz="${logsz:-0}"
  # The LOG, not the .id: .id is written once, at thread creation.
  act="$STATE_DIR/$name.log"
  [ -f "$act" ] || act="$STATE_DIR/$name.id"
  [ -f "$act" ] || act="$STATE_DIR/$name.active"
  mtime="$(_mtime "$act")"
  topic="$(head -1 "$STATE_DIR/$name.topic" 2>/dev/null | tr -d '\t\r')"
  busy=""
  live_lease "$STATE_DIR/$name.active" && busy=busy
  if [ "$mode" = --tsv ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${topic:--}" "$rounds" "$logsz" "$mtime" "${busy:--}"
  else
    printf '%-30s  %-7s  %-9s  %-16s  %s%s\n' "$name" "$rounds" "$logsz" "$mtime" "${topic:--}" "${busy:+  [busy]}"
  fi
done
