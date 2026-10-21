---
description: Sends a message to an arbitrarily named, writable Codex thread and creates it on first use. User-invoked only, for a conversation that does not fit /ask, /review or /plan, such as asking Codex to make an edit.
argument-hint: "[--topic <text>] [--oneshot] [--model <m>] [--effort <e>] <thread-name> <message>"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh *)
disable-model-invocation: true
---

# /thread

Arbitrary named-thread variant of `/review` and `/plan` — a plain passthrough with no intent framing. Use to keep parallel Codex conversations isolated by topic.

## Steps

1. Parse leading `--oneshot`, `--topic <text>`, `--model <m>` and `--effort <e>` flags, in any
   order, and pass them through to the driver. The next token is the thread name (must
   match `[a-zA-Z0-9_.-]+`); the rest is the prompt body.

2. If the thread name is missing or invalid, show usage and stop:

   ```
   Usage: /thread [--oneshot] [--topic <text>] [--model <m>] [--effort <e>] <name> <message>
   Name must be [a-zA-Z0-9_.-]+. Example: /thread migration-rls "explain..."
   ```

3. A pasted third-party review follows the skill's Reviews section (one classification pass).

4. Run via Bash tool (timeout 600000 — the caller's ceiling, not the dispatch's):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <NAME> [--topic "<text>"] [--oneshot] \
     [--model "$MODEL"] [--effort "$EFFORT"] <<< "<PROMPT_BODY>"
   ```

5. Show Codex's reply verbatim. On a non-zero exit, act per the Exit codes table of the skill `codex-triage`.

## Notes

- Thread state is local to the current worktree.
- A thread keeps the sandbox it was created with; a dispatch to a thread that holds required-review state revokes its recorded approval (skill: Threads).
- `/thread-list` shows all active named threads.
- `/thread-new <name>` forces a fresh exec (loses prior memory).
