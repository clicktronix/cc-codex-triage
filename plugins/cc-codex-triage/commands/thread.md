---
description: Send a message to an arbitrarily-named Codex thread; creates it on first use. For triage topics that don't fit the default review/plan threads.
argument-hint: "[--topic <text>] [--oneshot] <thread-name> <message>"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh *)
disable-model-invocation: true
---

# /thread

Arbitrary named-thread variant of `/review` and `/plan` — a plain passthrough with no intent framing. Use to keep parallel Codex conversations isolated by topic.

## Steps

1. Parse leading `--oneshot` and `--topic <text>` flags, in either order, and
   pass them through to the driver. The next token is the thread name (must
   match `[a-zA-Z0-9_.-]+`); the rest is the prompt body.

2. If the thread name is missing or invalid, show usage and stop:

   ```
   Usage: /thread [--oneshot] [--topic <text>] <name> <message>
   Name must be [a-zA-Z0-9_.-]+. Example: /thread migration-rls "explain..."
   ```

3. If the prompt is a third-party review, follow the one-pass classification rule in the skill's Reviews section.

4. Run via Bash tool (timeout 600000 — the caller's ceiling, not the dispatch's):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <NAME> [--topic "<text>"] [--oneshot] <<< "<PROMPT_BODY>"
   ```

5. Show Codex's reply verbatim. Handle exit code 4 (resume failure) and code 5 (file mutation) the same way as `/review`.

## Notes

- Thread state is local to the current worktree.
- `/thread-list` shows all active named threads.
- `/thread-new <name>` forces a fresh exec (loses prior memory).
