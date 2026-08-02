---
description: Send a message to an arbitrarily-named Codex thread; creates it on first use. For triage topics that don't fit the default review/plan threads.
argument-hint: "[--topic <text>] [--oneshot] <thread-name> <message>"
allowed-tools: Bash
disable-model-invocation: true
---

# /thread

Arbitrary named-thread variant of `/review` and `/plan` — a plain passthrough with no intent framing. Use to keep parallel Codex conversations isolated by topic.

## Steps

1. Parse `$ARGUMENTS`: an optional leading `--oneshot` (pass through to the driver), then the first whitespace-delimited token is the thread name (must match `[a-zA-Z0-9_.-]+`); the rest is the prompt body.

2. If the thread name is missing or invalid, show usage and stop:

   ```
   Usage: /thread [--oneshot] <name> <message>
   Name must be [a-zA-Z0-9_.-]+. Example: /thread migration-rls "explain..."
   ```

3. Apply Judge-mode framing per skill `codex-triage` if the prompt body looks like a third-party review.

4. Run via Bash tool (timeout 600000 — the caller's ceiling, not the dispatch's):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" <NAME> [--topic "<text>"] [--oneshot] <<< "<PROMPT_BODY>"
   ```

   `dispatch.sh` detaches the worker and then waits for it here, bounded below
   the caller's ceiling. A short dispatch returns the reply in this turn exactly
   as a direct call would; one that outruns the window **exits 20 and hands off**
   — the worker is untouched, and re-running the `detach-watch.sh` line it prints
   as a background task delivers the reply. Never treat exit 20 as a failure: the
   dispatch is still running and is already paid for.

5. Show Codex's reply verbatim. Handle exit code 4 (resume failure) and code 5 (file mutation) the same way as `/review`.

## Notes

- Thread state at `.claude/codex-threads/<name>.id`.
- `/thread-list` shows all active named threads.
- `/thread-new <name>` forces a fresh exec (loses prior memory).
