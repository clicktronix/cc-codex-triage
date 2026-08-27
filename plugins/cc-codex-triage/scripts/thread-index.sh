#!/usr/bin/env bash
# cc-codex-triage — what threads exist in this repo, and what each is about.
#
# usage: thread-index.sh [--tsv]
#
# Default output is a human table; --tsv is one record per line
# (name, topic, rounds, log bytes, last activity, busy) for a caller that wants
# to pick a thread rather than show one.
#
# Read-only, no Codex dispatch — the model-invocable review workflow may run
# it to reuse the correct task thread.
#
# Threads are listed by their `.id` file, so a name with state but no session
# (a failed first dispatch) is deliberately absent: there is nothing to resume.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "Not inside a git repository."; exit 0; }
cd "$ROOT" || exit 0
STATE_DIR="$(bash "$(cd "$(dirname "$0")" && pwd)/state-dir.sh" --read-only)" || exit $?
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
  # The LOG, not the .id: .id is written once, at thread creation.
  act="$STATE_DIR/$name.log"; [ -f "$act" ] || act="$f"
  mtime="$(_mtime "$act")"
  topic="$(head -1 "$STATE_DIR/$name.topic" 2>/dev/null | tr -d '\t\r')"
  # A live lease means a dispatch is in flight; targeting it would be refused
  # with exit 10, so a caller choosing a thread needs to know before it tries.
  busy=""
  if [ -f "$STATE_DIR/$name.active" ]; then
    # Same grammar as the driver, on the same bytes, with NO repair: stripping
    # whitespace or non-digits turns a lease the driver calls stale into a busy
    # row. No bare or leading zero — `kill -0 0` signals the process group.
    pid="$(cat "$STATE_DIR/$name.active" 2>/dev/null)"
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
