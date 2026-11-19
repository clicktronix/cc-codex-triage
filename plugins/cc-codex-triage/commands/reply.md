---
description: Sends a reply from Claude Code into an existing Codex thread. Use when Codex asked a question, requested a tool action (run a test, show a file), proposed options, or made a finding that needs pushback. Continues a conversation that already exists; to start a new one use /ask, /review or /plan.
argument-hint: "[--thread <name> | thread-name] [--model <m>] [--effort <e>] <directive or position>"
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/state-dir.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/thread-index.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh *)
---

# /reply

Continue the existing conversation under the shared skill's Ownership and Prompt boundary rules.

1. Prefer the explicitly requested name (`--thread NAME` or a named positional thread), then the thread
   used in this Claude conversation. Pass that name to `thread-index.sh --resolve NAME`. With neither,
   run `thread-index.sh --resolve` for the sole thread in this worktree. Exit 8 lists the candidates:
   ask once which to continue. Exit 6 reports a missing thread and the available names.
   Ordinary reply text is the directive. Preserve an explicitly named missing target.

2. Resolve `STATE_DIR` with `state-dir.sh --read-only` and run `review-state.sh mode "$THREAD"`. For `required`, use the saved base and spec from
   `$STATE_DIR/$THREAD.review-loop` and follow
   `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/required-review.md`.
   Reconcile a pending claim first. Resume a renewed grant on the same thread.
   For `advisory` continue below.

3. Recover Codex's last message: read the tail of `$STATE_DIR/<thread>.log` (the most recent `REPLY:` block). If the log has rotated, the latest entry is in the current `.log`; older history is in `.log.1`.

4. Classify what Codex's last message needs:
   - **Question** → answer it from project state (native task list, plan, recent conversation).
   - **Tool request** (run a test, show a file, grep) → run checks inside the owner's delegated scope and budget. Return the relevant result and excerpt.
   - **Options A/B/C** → state the user's choice (from the directive) with a one-line reason; ask Codex to detail it.
   - **Finding you disagree with** → push back with file:line evidence.

5. Compose a concise reply that answers what Codex asked, with the evidence, and send it through
   the dispatch wrapper, which survives long Codex runs. The thread keeps the sandbox it was
   created with, so the reply passes no sandbox flag (see the skill's Sandbox paragraph).
   `--model` / `--effort` are forwarded when supplied:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" --require-existing \
     ${MODEL:+--model "$MODEL"} ${EFFORT:+--effort "$EFFORT"} <<< "$REPLY_TEXT"
   ```

6. Show the updated findings/verdict and link the full log. On a non-zero exit, act per the Exit codes table of the skill `codex-triage`.
