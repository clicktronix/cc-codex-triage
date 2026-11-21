---
description: Lists this context's Codex threads, to pick one to reuse or retire.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/thread-index.sh *)
---

# /thread-list

## Steps

1. Run via Bash tool:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/thread-index.sh"
   ```

2. Use the listing to select/reuse or retire owned idle threads; show it when requested. Columns: thread, rounds, log size, last activity, topic. A `[busy]` marker means a dispatch is in flight on that thread — targeting it now would be refused (exit 10).
