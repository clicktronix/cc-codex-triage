---
description: Force-reset a named Codex thread — next message to it starts a fresh `codex exec` and loses prior conversation memory.
argument-hint: "<thread-name> [optional first message]"
allowed-tools: Bash
disable-model-invocation: true
---

# /thread-new

Drops the saved session UUID for the named thread so the next dispatch starts fresh. The Codex-side rollout file in `~/.codex/sessions/` is NOT deleted (Codex CLI manages those) — only shared repository state is cleared.

That reset also clears the thread's **required-review** state — `.candidate`, `.review-state`, `.review-loop`, and `.approved` — so this command is the only way out of a `CAP_REACHED` or `DIVERGED` hard stop. Clearing them discards a recorded approval as well: after this the candidate must earn a fresh one.

## Steps

1. Parse first token from `$ARGUMENTS` as the thread name. Validate `[a-zA-Z0-9_.-]+`.

2. If no further text after the name → just drop the pointer:

   ```bash
   # The driver holds the same active lease used by dispatch for the complete
   # reset. A concurrent dispatch therefore wins or loses before any sidecar is
   # removed; there is no reset-review-state, then delete-pointer TOCTOU gap.
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" "$THREAD" --reset-only </dev/null
   echo "Thread '$THREAD' reset. Next /thread, /review, or /plan invocation starts fresh."
   ```

3. If an additional prompt is given on the same line → drop the pointer AND immediately fire the prompt with `--new`:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" "$THREAD" --new <<< "$PROMPT"
   ```

4. Show Codex's reply (if step 3 ran) or the reset confirmation (if step 2 ran).

## When to use

- Codebase has drifted significantly from when the thread started — old context is now misleading.
- Resume failure (exit code 4 from the driver) — the saved UUID points at a dead session.
- A required review hard-stopped with `CAP_REACHED` or `DIVERGED`, the user has decided how to proceed, and the delivery workflow needs a fresh required lifecycle on that thread.
- You want to A/B compare a fresh Codex take vs the running thread's view.
