---
description: Run a structured multi-round debate between Claude Code and Codex on a design decision or question, with every exchange visible to the user. Ends in an honest synthesis, not forced consensus.
argument-hint: "[--rounds N] [--thread <name>] <question or decision to debate>"
allowed-tools: Bash
disable-model-invocation: true
---

# /debate

Claude Code and Codex argue a question over N rounds in a persistent thread. The user sees every exchange: your position, Codex's reply (verbatim), your rebuttal. **Follow the "Debating Codex" rules in skill `codex-triage` throughout** — they are the load-bearing part of this command.

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--rounds N` → number of argument rounds before synthesis (default `3`, max `5`).
   - `--thread <name>` → thread name (default: `debate-<short-slug-of-topic>`; one debate = one thread, never reuse).
   The remainder is the question/decision under debate.

2. **Commit to your position first.** Investigate as needed (read code/docs), then state YOUR position with evidence — visibly, to the user — BEFORE dispatching anything to Codex. This is the commitment device against capitulation.

3. Open the debate (round 1). Send via Bash (timeout 600000):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> <<< "$OPENING"
   ```

   `$OPENING` template:

   ```
   We are having a structured debate. Topic:
   <topic>

   My position (Claude Code):
   <your position + evidence>

   Your role: take the strongest independent stance on this topic — agree only
   where the evidence genuinely compels it, and argue the opposing case wherever
   it is defensible. Rules for both of us: every claim needs evidence (file:line,
   docs, measurements); concede a point only by naming the evidence that changed
   your assessment; no agreement theater. State your position and your strongest
   arguments. You may read the repo to ground them.
   ```

4. Show Codex's reply verbatim. Then compose your rebuttal **following the skill's anti-capitulation rules** (concede only on named evidence; advance or sharpen; no unearned middle ground), show it to the user, and dispatch it to the same thread. Repeat until N rounds are spent — or stop early if a round adds nothing new (say so).

5. **Synthesis round.** Send: `Final round — synthesis. List: (1) points we agree on, (2) residual disagreements stated plainly, (3) what changed your mind, if anything, and on what evidence. Recommend a course of action, admitting uncertainty where it exists.` Show Codex's synthesis verbatim, then add YOUR closing synthesis: agreements, honest residual disagreements, what changed your mind and why, and your recommendation to the user. If you and Codex still disagree, present both options to the user — do not fake a winner.

6. Handle driver exit code 4 (resume failed) per the skill — ask before `--new` (a broken debate thread loses the whole exchange).

## Notes

- Thread: `.claude/codex-threads/debate-<slug>.{id,log,rounds}` — the full exchange is auditable in the `.log`.
- The debate costs ~(N+1) Codex dispatches; tell the user the round count before starting if the topic looks small enough for a plain `/ask`.
- For "critique my code/plan" use `/review` / `/plan` — a debate is for genuine decision disagreements with defensible positions on both sides.
