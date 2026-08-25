---
description: Compose a reply from Claude Code back into an active Codex thread. Use when Codex asked a question, requested a tool action (run a test, show a file), proposed options, or made a finding that needs pushback.
argument-hint: "[thread-name] <directive or position>"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)
disable-model-invocation: true
---

# /reply

Sends a reply from Claude Code into an existing Codex thread. Follow the skill's prompt-boundary and evidence rules: represent the user's position, execute tool requests for real, and push back with evidence.

## Steps

1. Resolve `STATE_DIR` with `state-dir.sh`. If the first token names an existing thread (`$STATE_DIR/<token>.id`), use it. Otherwise use `${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh review`. If that thread does not exist, stop and ask the user to start one with `/ask`, `/review`, or `/plan`; never fall back to unrelated legacy state.

2. Recover Codex's last message: read the tail of `$STATE_DIR/<thread>.log` (the most recent `REPLY:` block). If the log has rotated, the latest entry is in the current `.log`; older history is in `.log.1`.

3. Classify what Codex's last message needs:
   - **Question** → answer it from project state (TodoWrite, plan, recent conversation).
   - **Tool request** (run a test, show a file, grep) → actually DO it with your tools, capture verbatim output, include it.
   - **Options A/B/C** → state the user's choice (from the directive) with a one-line reason; ask Codex to detail it.
   - **Finding you disagree with** → push back with file:line evidence.

4. Compose the reply (≤500 words) and pipe to the driver:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" <THREAD> --require-existing <<< "$REPLY_TEXT"
   ```

   `dispatch.sh` detaches the worker and then waits for it here, bounded below
   the caller's ceiling. A short dispatch returns the reply in this turn exactly
   as a direct call would; one that outruns the window **exits 20 and hands off**
   — the worker is untouched, and re-running the `detach-watch.sh` line it prints
   as a background task delivers the reply. Never treat exit 20 as a failure: the
   dispatch is still running and is already paid for.

5. Show Codex's next reply verbatim. Handle exit code 4 (resume failed) per the skill — ask before `--new`. Exit code 6 means no such thread — see step 1.

## Notes

- `/reply` only makes sense for a thread that already exists. If none does, you probably want `/ask`, `/review`, or `/plan` to start one.
- Thread state is local to the current worktree.
