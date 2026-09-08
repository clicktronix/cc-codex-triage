---
description: Ask OpenAI Codex CLI an informational question in a persistent thread. Use for "how does X work here", "is there already a Y", "what's the idiomatic way to Z" — exploration, not critique. Pass --thread to keep a feature's questions with the rest of that feature's context.
argument-hint: '[--thread <name>] [--topic <text>] [--oneshot] <question>'
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh *)
---

# /ask

Sends an informational question to a persistent Codex thread — the worktree-local `ask` thread by default, or a named one via `--thread`. Follow-up questions continue the same thread, so Codex retains prior Q&A. Use `--oneshot` for a throwaway question that leaves no thread state.

This is the **informational** command — collaborative, not adversarial. For critique of your code use `/review`; for stress-testing a plan use `/plan`.

## Steps

1. Parse `$ARGUMENTS`:
   - `--thread <name>` → target thread (must match `[a-zA-Z0-9_.-]+`). **Default: `ask`**, a single repo-wide thread for one-off questions.
   - `--topic <text>` → one-line label recorded when the thread is CREATED, so `/thread-list` and a later agent can tell what it holds. Ignored on an existing thread.
   - `--oneshot` → strip it and pass `--oneshot` to the driver.
   The rest is the question. See **Thread choice** below for which thread to target.

2. Compose `$QUESTION`: prepend this framing to the user's question so Codex answers rather than acts:

   ```
   Answer this question about the project. You may read files and run read-only
   commands to ground your answer, but do NOT edit anything or perform a full
   code review — just answer.

   <the question>
   ```

3. Run via Bash (timeout 600000 — the caller's ceiling, not the dispatch's).
   `--read-only` applies to both new and resumed calls, including a thread that
   previously used a writable configuration.

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> --read-only \
     [--topic "<text>"] [--oneshot] <<< "$QUESTION"
   ```

   `/ask` is a short foreground question. Use `/review`, `/plan`, or `/debate`
   when the work may need long-running handoff.

4. Answer with Codex's evidence and uncertainty; link the full log when summarizing.

5. Handle driver exit code 4 (resume failed) per skill `codex-triage` — ask the user before `--new`, do not auto-reset.

## Thread choice

The default `ask` thread is repo-wide — right for "is there already a helper for X", wrong for anything belonging to a feature you are working through. Point those at that feature's thread with `--thread <feature>`, following the skill's Threads section.

## Notes

- Thread state is local to the current worktree; default thread: `ask`.
- External worktree movement can still trigger the mutation guard; do not attribute it to Codex without evidence.
- Need write access (e.g. "try this fix")? That is a different intent — use `/thread <name>` without the read-only default, or `/review`.
- Force-reset: `/thread-new <thread>`.
