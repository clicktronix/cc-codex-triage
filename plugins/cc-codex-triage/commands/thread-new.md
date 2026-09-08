---
description: Force-reset a named Codex thread so its next normal command starts a fresh `codex exec` without prior conversation memory.
argument-hint: "<thread-name>"
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh *)
---

# /thread-new

Drops the saved session UUID for the named thread so the next dispatch starts fresh. The Codex-side rollout file in `~/.codex/sessions/` is NOT deleted (Codex CLI manages those) — the context's plugin state is archived before its current session/approval is cleared.

That reset also clears the thread's **required-review** state — `.candidate`, `.review-state`, `.review-loop`, and `.approved` — so it starts a new lifecycle. Never use it to bypass `CAP_REACHED` or unresolved findings. Clearing them discards a recorded approval as well: after this the candidate must earn a fresh one.

## Steps

Use autonomously to retire an owned, idle, obsolete advisory conversation or recover
one that cannot resume. Inspect its topic/log and task state first. Retain threads
needed by active work or required delivery; do not mass-reset unrelated sessions. A
new required lifecycle after cap still needs the outstanding user decision.

1. Parse first token from `$ARGUMENTS` as the thread name. Validate `[a-zA-Z0-9_.-]+`.

2. Refuse extra text; this command resets state but never starts a paid dispatch.
   Run:

   ```bash
   # The driver holds the same active lease used by dispatch for the complete
   # reset. A concurrent dispatch therefore wins or loses before any sidecar is
   # removed; there is no reset-review-state, then delete-pointer TOCTOU gap.
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" "$THREAD" --reset-only </dev/null || exit $?
   echo "Thread '$THREAD' reset. The next command targeting it starts fresh."
   ```

3. Report the reset and archive location briefly. Reset retires the session; it does
   not delete its archive or Codex rollout history.

## When to use

- Codebase has drifted significantly from when the thread started — old context is now misleading.
- Resume failure (exit code 4 from the driver) — the saved UUID points at a dead session.
- A required review hard-stopped with `CAP_REACHED`, the user has decided how to proceed, and the delivery workflow needs a fresh required lifecycle on that thread.
- You want to A/B compare a fresh Codex take vs the running thread's view.
