---
description: Retires one named Codex thread so its next command starts a fresh `codex exec` without prior conversation memory, and clears any required-review state on it. Use for an obsolete or unresumable advisory thread, or a user-authorized change of a required review's base, spec or cap.
argument-hint: "<thread-name>"
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh *)
---

# /thread-new

Drops the saved session UUID for the named thread so the next dispatch starts fresh. The Codex-side rollout file in `~/.codex/sessions/` is kept (Codex CLI manages those) — the context's plugin state is archived before its current session/approval is cleared.

The reset also clears the thread's **required-review** state — `.candidate`, `.review-state`, `.review-loop`, and `.approved` — and starts a new lifecycle, discarding a recorded approval: the candidate must earn a fresh one.

## Steps

1. Parse the first token of `$ARGUMENTS` as the thread name and validate `[a-zA-Z0-9_.-]+`. Extra text is refused: this command resets state and starts no paid dispatch.

2. Inspect the thread's topic, log and task state first, and reset one thread at a time. Run:

   ```bash
   # The driver holds the same active lease used by dispatch for the complete
   # reset. A concurrent dispatch therefore wins or loses before any sidecar is
   # removed; there is no reset-review-state, then delete-pointer TOCTOU gap.
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" "$THREAD" --reset-only </dev/null || exit $?
   echo "Thread '$THREAD' reset. The next command targeting it starts fresh."
   ```

3. Report the reset and archive location briefly. The archive and the Codex rollout history stay.

## When to use

- The codebase has drifted since the thread started and old context misleads.
- Resume failed (driver exit 4) and the saved UUID points at a dead session.
- A user-authorized change of a required review's base, spec or cap needs a fresh lifecycle.
- Damaged required-review state that its Recovery section says to reset: see
  `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/required-review.md`.
- A fresh Codex take is wanted for comparison with the running thread's view.
