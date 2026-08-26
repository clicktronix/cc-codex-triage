---
description: Run a structured multi-round debate between Claude Code and Codex on a design decision or question, with every exchange visible to the user. Ends in an honest synthesis, not forced consensus.
argument-hint: "[--rounds N] [--thread <name>] [--topic <text>] <question or decision to debate>"
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh *)
disable-model-invocation: true
---

# /debate

Claude Code and Codex argue a question over N rounds in a persistent thread. The user sees every exchange: your position, Codex's reply (verbatim), your rebuttal. Follow the Debate section of skill `codex-triage` throughout.

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--rounds N` → maximum number of argument rounds before synthesis (default `5`, max `15`). This is a ceiling, not a target: the "advance or sharpen" rule below ends the debate early once a round stops adding new evidence, so a deep disagreement can use all 15 while a shallow one wraps in 2–3.
   - `--thread <name>` → thread name (default: `debate-<short-slug-of-topic>`; one debate = one thread, never reuse).
   - `--topic <text>` → one-line label recorded when the thread is CREATED, so `/thread-list` and a later agent can tell what it holds. Ignored on an existing thread.
   The remainder is the question/decision under debate.

2. **Commit to your position first.** Investigate as needed (read code/docs), then state YOUR position with evidence — visibly, to the user — BEFORE dispatching anything to Codex. This is the commitment device against capitulation.

3. Open the debate (round 1). Send via Bash (timeout 600000 — the caller's ceiling, not the dispatch's):

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" <THREAD> [--topic "<text>"] <<< "$OPENING"
   ```

   Handle long-dispatch handoff as defined by skill `codex-triage`.

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

4. Compose and dispatch the rebuttal following the skill's Debate rules. Present
   the exchange in the format below. Stop early when a round adds nothing new.

5. **Synthesis round.** Send: `Final round — synthesis. List: (1) points we agree on, (2) residual disagreements stated plainly, (3) what changed your mind, if anything, and on what evidence. Recommend a course of action, admitting uncertainty where it exists.` Then render the **Result** block (below) from both your and Codex's synthesis. If you and Codex still disagree, present both options to the user — do not fake a winner.

6. Handle driver exit code 4 (resume failed) per the skill — ask before `--new` (a broken debate thread loses the whole exchange).

## Presentation format

Render one labelled block per speaker per round, then one Result block.

Each round looks like this (the `---` rules are the "frames"):

```
---
### Round N

**Claude Code**

<your argument — plain language in the conversation's language, evidence as inline file:line. NO rule-labels ("уступаю с называнием доказательства", "residual ... на котором не уступаю", "вопрос на спор"); NO untranslated English jargon (wedge/moat/residual/sequencing).>

**Codex**

<Codex's reply, VERBATIM — never paraphrase, trim, or summarise it; it may carry its own markdown, that's fine>
---
```

Round 1 also shows your committed opening position (step 2) as the first **Claude Code** block. After the final round, close with:

```
### Result

- **Agreed:** …
- **Still open:** … (residual disagreements stated plainly — do not fake a winner)
- **What moved, on what evidence:** …
- **Recommendation:** … (if still split, both options for the user to decide)
```

## Notes

- Thread: `debate-<slug>.{id,log,rounds}` in worktree-local state — the full exchange is auditable in the `.log`.
- The debate costs up to ~(N+1) Codex dispatches (fewer if it ends early). At the higher round counts this adds up — for `--rounds 10`+ confirm the cost with the user before starting, and for a small topic suggest a plain `/ask` instead.
- For "critique my code/plan" use `/review` / `/plan` — a debate is for genuine decision disagreements with defensible positions on both sides.
