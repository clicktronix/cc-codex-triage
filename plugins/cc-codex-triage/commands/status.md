---
description: One-screen status of cc-codex-triage in this repo — current branch, dirty tree, armed /autoreview /autoplan gates (with stale-branch / pre-0.5 / missing-target warnings), last verdict per thread, gitignore status, and the Codex CLI version. Read-only.
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
   - *state dir not gitignored* → add `.claude/codex-threads/` to `.gitignore`.
   - *codex CLI below required / not found* → upgrade or install per the message.
