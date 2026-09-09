---
description: Show the current context's Codex threads, retained archives, required-review state, working tree, and Codex CLI version. Read-only.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/status.sh *)
---

# /status

Run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Inspect the output for the current task; summarize relevant state or show it when requested. `APPROVED` is still only a recorded state; an owning
workflow must run `review-state.sh check <thread>` before delivery.
