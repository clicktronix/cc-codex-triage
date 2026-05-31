---
description: Send a message to an arbitrarily-named Codex thread; creates it on first use. For triage topics that don't fit the default review/plan threads.
argument-hint: <thread-name> <message>
allowed-tools: Bash
disable-model-invocation: true
---

# /codex-thread

Arbitrary named-thread variant of `/codex-review` and `/codex-plan`. Use when you want to keep parallel Codex conversations isolated by topic.

## Steps

1. Parse `$ARGUMENTS`: first whitespace-delimited token is the thread name (must match `[a-zA-Z0-9_.-]+`); the rest is the prompt body.

2. If the thread name is missing or invalid, show usage and stop:

   ```
   Usage: /codex-thread <name> <message>
   Name must be [a-zA-Z0-9_.-]+. Example: /codex-thread migration-rls "explain..."
   ```

3. Apply Judge-mode framing per skill `codex-triage` if the prompt body looks like a third-party review.

4. Run via Bash tool (timeout 600000):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <NAME> <<< "<PROMPT_BODY>"
   ```

5. Show Codex's reply verbatim. Handle exit code 4 (resume failure) and code 5 (file mutation) the same way as `/codex-review`.

## Notes

- Thread state at `.claude/codex-threads/<name>.id`.
- `/codex-thread-list` shows all active named threads.
- `/codex-thread-new <name>` forces a fresh exec (loses prior memory).
