#!/usr/bin/env bash
# cc-codex-triage — what threads exist in this repo, and what each is about.
#
# usage: thread-index.sh [--tsv]
#
# Default output is a human table; --tsv is one record per line
# (name, topic, rounds, log bytes, last activity, busy) for a caller that wants
# to pick a thread rather than show one.
#
# This exists because every slash command is disable-model-invocation, so an
# agent told to "reuse the feature's thread" had no way to see which threads
# exist or what they hold. Reading it costs nothing — no Codex dispatch — which
# is why the codex-second-opinion skill may run it unprompted.
#
# Threads are listed by their `.id` file, so a name with state but no session
# (a failed first dispatch) is deliberately absent: there is nothing to resume.
set -u
# Shared helpers rather than private copies: the inline mtime this script used
# to carry inherited a Linux bug from the same pattern in lib.sh.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "Not inside a git repository."; exit 0; }
cd "$ROOT" || exit 0
STATE_DIR=".claude/codex-threads"
TSV=false
[ "${1:-}" = "--tsv" ] && TSV=true

[ -d "$STATE_DIR" ] || { $TSV || echo "No active threads in this repo."; exit 0; }
set -- "$STATE_DIR"/*.id
[ -e "$1" ] || { $TSV || echo "No active threads in this repo."; exit 0; }

$TSV || printf '%-30s  %-7s  %-9s  %-16s  %s\n' THREAD ROUNDS LOG_SIZE LAST_ACTIVITY TOPIC

for f in "$@"; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .id)"
  rounds="$(cat "$STATE_DIR/$name.rounds" 2>/dev/null | tr -cd '0-9')"; rounds="${rounds:-0}"
  logsz="$(wc -c 2>/dev/null < "$STATE_DIR/$name.log" | tr -d ' ')"; logsz="${logsz:-0}"
  # The LOG, not the .id: the driver writes .id once, on the dispatch that
  # creates the thread, and never again — so stat'ing it reports creation time
  # under a "last activity" heading. The log is appended every round.
  act="$STATE_DIR/$name.log"; [ -f "$act" ] || act="$f"
  mtime="$(_mtime "$act")"
  topic="$(head -1 "$STATE_DIR/$name.topic" 2>/dev/null | tr -d '\t\r')"
  # A live lease means a dispatch is in flight; targeting it would be refused
  # with exit 10, so a caller choosing a thread needs to know before it tries.
  busy=""
  if [ -f "$STATE_DIR/$name.active" ]; then
    # RAW, not `tr -cd '0-9'`: stripping non-digits turns malformed content like
    # "garbage123" into a live PID and reports the thread busy, while the driver
    # treats that same lease as stale and dispatchable. Same grammar as the
    # driver: positive decimal, no leading zero, bounded length. (`kill -0 0`
    # would also signal the whole process group.)
    pid="$(head -1 "$STATE_DIR/$name.active" 2>/dev/null | tr -d ' \t\r\n')"
    case "$pid" in ''|0|0*|*[!0-9]*) pid="" ;; esac
    [ "${#pid}" -le 12 ] || pid=""
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && busy="busy"
  fi
  if $TSV; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${topic:--}" "$rounds" "$logsz" "$mtime" "${busy:--}"
  else
    printf '%-30s  %-7s  %-9s  %-16s  %s%s\n' "$name" "$rounds" "$logsz" "$mtime" "${topic:--}" "${busy:+  [busy]}"
  fi
done
