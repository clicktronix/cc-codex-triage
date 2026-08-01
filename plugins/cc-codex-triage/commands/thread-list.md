---
description: List active named Codex threads in the current repo with rounds, log size, last activity, topic, and a busy marker for a thread with a dispatch in flight.
allowed-tools: Bash
disable-model-invocation: true
---

# /thread-list

Lists threads under `.claude/codex-threads/` in the current repo.

## Steps

1. Run via Bash tool:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/thread-index.sh"
   ```

2. Show output verbatim. Columns: thread, rounds, log size, last activity, topic. A `[busy]` marker means a dispatch is in flight on that thread — targeting it now would be refused (exit 10).

