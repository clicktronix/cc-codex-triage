---
description: Asks Codex a read-only informational question in a persistent thread, answered from the local repository and general knowledge. Use for "how does X work here", "is there already a Y", "what is the idiomatic way to Z". For current external sources or a sourced comparison of approaches use /research; for critique of code use /review; for a plan use /plan. Pass --thread to keep a feature's questions together.
argument-hint: '[--thread <name>] [--topic <text>] [--oneshot] [--model <m>] [--effort <e>] <question>'
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh *)
---

# /ask

Sends an informational question to a persistent Codex thread — the context-local `ask` thread by default, or a named one via `--thread`. Follow-up questions continue the same thread, so Codex retains prior Q&A. Use `--oneshot` for a throwaway question that leaves no thread state.

## Steps

1. Parse `$ARGUMENTS`:
   - `--thread <name>` → target thread (must match `[a-zA-Z0-9_.-]+`). **Default: `ask`**, a single context-wide thread for one-off questions.
   - `--topic <text>` → one-line label recorded when the thread is CREATED, so `/thread-list` and a later agent can tell what it holds. Ignored on an existing thread.
   - `--oneshot` → strip it and pass `--oneshot` to the driver.
   - `--model <m>`, `--effort <e>` → pass through when supplied; the skill's Threads section defines how a thread keeps them.
   The rest is the question. See **Thread choice** below for which thread to target.

2. Compose `$QUESTION`: prepend this framing to the user's question so Codex answers rather than acts.
   A repository is optional context, not a precondition — a general question outside Git gets the
   same framing and no project assumptions:

   ```
   Answer this question. When a repository is part of the context, you may read
   files and run read-only commands to ground your answer; a general question
   needs neither. Answer the question and stop there: leave files unedited and skip a full code review.

   <the question>
   ```

3. Run via Bash (timeout 600000 — the caller's ceiling, not the dispatch's).
   `--read-only` makes the thread read-only from creation (see the skill's Sandbox paragraph).

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" advisory-check <THREAD> || exit $?
   "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> --read-only \
     [--topic "<text>"] [--oneshot] [--model "$MODEL"] [--effort "$EFFORT"] <<< "$QUESTION"
   ```

   `/ask` is a short foreground question; `/review`, `/plan` and `/debate` handle long runs.

4. Answer with Codex's evidence and uncertainty; link the full log when summarizing.

5. On a non-zero exit, act per the Exit codes table of the skill `codex-triage`.

## Thread choice

The default `ask` thread is context-wide — right for "is there already a helper for X", wrong for anything belonging to a feature you are working through. Point those at that feature's thread with `--thread <feature>`, following the skill's Threads section.

## Notes

- Thread state is local to the current context; default thread: `ask`.
- A tracked-file status change reported by the driver may come from external worktree movement; attribute it to Codex only with evidence.
- Writes are the owning workflow's job: this command only answers.
