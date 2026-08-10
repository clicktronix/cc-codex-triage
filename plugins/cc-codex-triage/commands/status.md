---
description: One-screen status of cc-codex-triage in this repo — branch, working tree, shared state path, armed gates and cycle state, thread verdicts, required-review gate state, and Codex CLI version. Read-only.
allowed-tools: Bash
disable-model-invocation: true
---

# /status

Surfaces, in one view, the state that otherwise has to be hand-assembled from
`.armed` / `.rounds` / `.log` files plus `git`. Read-only — it never changes
anything.

## Steps

1. Run via Bash tool (no arguments):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
   ```

2. Show the output verbatim.

3. If any `WARNING` line appears, briefly tell the user what to do:
   - *armed for a different branch* → switch back to that branch to use the gate, or `/autoreview off` / `/autoplan off` to clear it.
   - *pre-0.5 armed file* → `/autoreview on` / `/autoplan on` to re-arm in the current format.
   - *target thread has no log/id* → the gate's thread name does not match any thread on disk; re-arm, or run the review/plan with that exact `--thread` name.
   - *the log's last verdict reads APPROVE but the required gate did not accept it* → Codex decorated the verdict (`## APPROVE`, `**APPROVE**`). The required gate takes the bare token on its own final line; re-run the round with that line restated. The advisory verdict column is not the gate.
   - *required gate HARD STOP (`CAP_REACHED` / `DIVERGED`)* → not an approval and not retryable: put the open findings to the user, then `/thread-new <thread>` to start a fresh required lifecycle.
   - *required gate claim EXPIRED / live* → a live claim means a round is in flight, so do not start another; an expired one is released by recording the finished dispatch or by `/thread-new <thread>`.
   - *codex CLI below required / not found* → upgrade or install per the message.
