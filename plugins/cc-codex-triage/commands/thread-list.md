---
description: List active named Codex threads in the current repo with their session UUIDs, round counts, log sizes, and last-activity timestamps.
allowed-tools: Bash
disable-model-invocation: true
---

# /thread-list

Lists threads under `.claude/codex-threads/` in the current repo.

## Steps

1. Run via Bash tool:

   ```bash
   cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
   STATE_DIR=".claude/codex-threads"
   if [ ! -d "$STATE_DIR" ]; then
     echo "No active threads in this repo."
     exit 0
   fi
   printf '%-26s  %-38s  %-7s  %-9s  %s\n' THREAD SESSION_UUID ROUNDS LOG_SIZE LAST_ACTIVITY
   for f in "$STATE_DIR"/*.id; do
     [ -f "$f" ] || continue
     name="$(basename "$f" .id)"
     sid="$(cat "$f")"
     rounds="$(cat "$STATE_DIR/$name.rounds" 2>/dev/null || echo 0)"
     logsz="$(wc -c < "$STATE_DIR/$name.log" 2>/dev/null | tr -d ' ' || echo 0)"
     mtime="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f" 2>/dev/null || stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)"
     printf '%-26s  %-38s  %-7s  %-9s  %s\n' "$name" "$sid" "$rounds" "${logsz:-0}" "$mtime"
   done
   ```

2. Show output verbatim.

3. If any thread has `LAST_ACTIVITY` older than 24h, add a note: "thread `<name>` has not been used for >24h — Codex still remembers it, but the codebase may have drifted from when the conversation started."
