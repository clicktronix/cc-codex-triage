---
description: Ask OpenAI Codex CLI an informational question in a persistent thread. Use for "how does X work here", "is there already a Y", "what's the idiomatic way to Z" — exploration, not critique. Pass --thread to keep a feature's questions with the rest of that feature's context.
argument-hint: '[--thread <name>] [--oneshot] <question>'
allowed-tools: Bash
disable-model-invocation: true
---

# /ask

Sends an informational question to a persistent Codex thread — the shared `ask` thread by default, or a named one via `--thread`. Follow-up questions continue the same thread, so Codex retains prior Q&A. Use `--oneshot` for a throwaway question that leaves no thread state.

This is the **informational** command — collaborative, not adversarial. For critique of your code use `/review`; for stress-testing a plan use `/plan`.

## Steps

1. Parse `$ARGUMENTS`:
   - `--thread <name>` → target thread (must match `[a-zA-Z0-9_.-]+`). **Default: `ask`**, a single repo-wide thread for one-off questions.
   - `--oneshot` → strip it and pass `--oneshot` to the driver.
   The rest is the question.

   **When to pass `--thread`.** The default `ask` thread is repo-wide, which is right for "is there already a helper for X" and wrong for anything belonging to a feature you are working through. Questions about a feature belong on that feature's thread, where Codex already has the context — see **One feature, one thread** below.

2. Compose `$QUESTION`: prepend this framing to the user's question so Codex answers rather than acts:

   ```
   Answer this question about the project. You may read files and run read-only
   commands to ground your answer, but do NOT edit anything or perform a full
   code review — just answer.

   <the question>
   ```

3. Pick the sandbox, then run via Bash (timeout 600000). Default to read-only — you are asking, not asking Codex to change anything — and respect a user-set `CC_CODEX_FLAGS`.

   **On an EXISTING thread, do not pass a sandbox flag.** The sandbox is fixed when a Codex session is created and `codex exec resume` does not accept `-s`, so a flag on a resume is silently ignored — setting it would only tell the user something untrue. Detect it the usual way: `.claude/codex-threads/<THREAD>.id` exists means resume.

   ```bash
   # initial dispatch on this thread (no .id yet) — the read-only default applies:
   CC_CODEX_FLAGS="${CC_CODEX_FLAGS:--s read-only}" \
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> [--oneshot] <<< "$QUESTION"

   # resume (.id exists) — the thread keeps the sandbox it was created with:
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> <<< "$QUESTION"
   ```

4. Show Codex's reply verbatim.

5. Handle driver exit code 4 (resume failed) per skill `codex-triage` — ask the user before `--new`, do not auto-reset.

## One feature, one thread

Threads default to one per *command kind* — `ask`, `review-<branch>`, `plan-<branch>`, `debate-<slug>` — so a single feature's context ends up split across three or four Codex sessions that each know a third of the story. When you are working a feature through, point `/ask`, `/plan` and `/debate` at ONE thread named for it (`--thread feat-391`), and leave `/review` on its own branch-scoped thread so the gate's verdict parsing stays clean.

Two things bound how far that goes:

- **The sandbox is fixed at session creation.** `codex exec resume` accepts `-m` and `--output-schema` but no `-s`, so a feature thread chooses its sandbox once, on the first dispatch. Read-only is usually right for a thread that answers and critiques — it is also the only setting under which Codex can never trip the tracked-file mutation guard.
- **A thread is not free to grow.** Every resume re-feeds the history: production feature threads reach ~130 KB by round 9, and the longest on record (13 rounds, ~135 KB) never converged. Past roughly 10 rounds or 100 KB — `/thread-list` shows both — start a fresh `--thread <feature>-2` with a short written handoff instead of resuming further.

## Notes

- Thread state: `.claude/codex-threads/<thread>.id`; audit log `.claude/codex-threads/<thread>.log`. Default thread: `ask`.
- A thread created with the read-only default never trips the tracked-file mutation guard.
- Need write access (e.g. "try this fix")? That is a different intent — use `/thread <name>` without the read-only default, or `/review`.
- Force-reset: `/thread-new <thread>`.
