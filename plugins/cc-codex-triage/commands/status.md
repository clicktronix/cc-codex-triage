---
description: Show the current worktree's Codex threads, required-review state, working tree, and Codex CLI version. Read-only.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/status.sh *)
disable-model-invocation: true
---

# /status

Run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
```

Show its output verbatim. `APPROVED` is still only a recorded state; an owning
workflow must run `review-state.sh check <thread>` before delivery.
