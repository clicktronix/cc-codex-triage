---
description: Ask OpenAI Codex CLI an informational question in a persistent "ask" thread. Use for "how does X work here", "is there already a Y", "what's the idiomatic way to Z" — exploration, not critique.
argument-hint: "[--oneshot] <question>"
allowed-tools: Bash
disable-model-invocation: true
---

# /ask

Sends an informational question to the persistent Codex thread `ask`. Follow-up questions continue the same thread, so Codex retains prior Q&A. Use `--oneshot` for a throwaway question that leaves no thread state.

This is the **informational** command — collaborative, not adversarial. For critique of your code use `/review`; for stress-testing a plan use `/plan`.

## Steps

1. Parse `$ARGUMENTS`: if it starts with `--oneshot`, strip it and pass `--oneshot` to the driver. The rest is the question.

2. Default the Codex sandbox to read-only — you are asking, not asking Codex to change anything. Respect a user-set `CC_CODEX_FLAGS`. Run via Bash (timeout 600000):

   ```bash
   CC_CODEX_FLAGS="${CC_CODEX_FLAGS:--s read-only}" \
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" ask [--oneshot] <<< "$QUESTION"
   ```

3. Prepend this one-line framing to `$QUESTION` so Codex answers rather than acts:

   ```
   Answer this question about the project. You may read files and run read-only
   commands to ground your answer, but do NOT edit anything or perform a full
   code review — just answer.

   <the question>
   ```

4. Show Codex's reply verbatim.

5. Handle driver exit code 4 (resume failed) per skill `codex-triage` — ask the user before `--new`, do not auto-reset.

## Notes

- Thread state: `.claude/codex-threads/ask.id`; audit log `.claude/codex-threads/ask.log`.
- The `ask` thread is created read-only, so it never trips the tracked-file mutation guard.
- Need write access (e.g. "try this fix")? That is a different intent — use `/thread <name>` without the read-only default, or `/review`.
- Force-reset: `/thread-new ask`.
