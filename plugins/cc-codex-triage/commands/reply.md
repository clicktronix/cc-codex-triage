---
description: Compose a reply from Claude Code back into an active Codex thread. Use when Codex asked a question, requested a tool action (run a test, show a file), proposed options, or made a finding that needs pushback.
argument-hint: "[thread-name] <directive or position>"
allowed-tools: Bash, Read, Glob, Grep
disable-model-invocation: true
---

# /reply

Sends a reply from Claude Code into an existing Codex thread. This is the one place CC speaks back to Codex rather than forwarding the user — so the reverse-sycophancy rules in skill `codex-triage` apply: represent the user's position, execute tool requests for real, push back with evidence.

## Steps

1. Parse `$ARGUMENTS`: if the first token names an existing thread (`.claude/codex-threads/<token>.id` exists), that is the target thread; the rest is the directive. Otherwise target `review` and treat all of `$ARGUMENTS` as the directive. Replying only makes sense for a thread that already exists — the driver is invoked with `--require-existing` (step 4), which exits 6 rather than silently starting a new thread. If that happens, tell the user to start one first with `/ask`, `/review`, or `/plan`.

2. Recover Codex's last message: read the tail of `.claude/codex-threads/<thread>.log` (the most recent `REPLY:` block). If the log has rotated, the latest entry is in the current `.log`; older history is in `.log.1`.

3. Classify what Codex's last message needs, then **follow the "Answering Codex back" rules in skill `codex-triage`**:
   - **Question** → answer it from project state (TodoWrite, plan, recent conversation).
   - **Tool request** (run a test, show a file, grep) → actually DO it with your tools, capture verbatim output, include it.
   - **Options A/B/C** → state the user's choice (from the directive) with a one-line reason; ask Codex to detail it.
   - **Finding you disagree with** → push back with file:line evidence.

4. Compose the reply (≤500 words) and pipe to the driver:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> --require-existing <<< "$REPLY_TEXT"
   ```

5. Show Codex's next reply verbatim. Handle exit code 4 (resume failed) per the skill — ask before `--new`. Exit code 6 means no such thread — see step 1.

## Notes

- `/reply` only makes sense for a thread that already exists. If none does, you probably want `/ask`, `/review`, or `/plan` to start one.
- Thread state: `.claude/codex-threads/<thread>.id` / `.log`.
