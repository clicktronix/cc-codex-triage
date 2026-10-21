---
description: Stress-tests one plan or architecture decision in a persistent Codex thread, iterating until APPROVE (or one pass with --once). Use to find gaps, risks and sequencing problems in a plan before executing it. For code that already exists use /review; for choosing among several competing options use /debate or --lens alternatives.
argument-hint: "[--lens <name>] [--thread <name>] [--topic <text>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] <plan or question>"
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh *)
---

# /plan

Stress-test a plan, revise validated gaps, and resume until `APPROVE`, only
optional comments remain, or the round cap is reached.

## Steps

1. Parse leading flags. The default thread comes from
   `${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh plan`; default lens is
   `stress-test`; default cap is 5. Iteration, `--once`, `--oneshot` and `--background`
   follow the skill's owner-call rules. A clearly different artifact needs a new thread.

2. On the initial dispatch, read the selected plan focus and output contract from
   `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md` and
   append the plan text or repo path. On resume, send only what changed and ask
   Codex to re-check its previous objections before finding new ones.

3. Dispatch:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" advisory-check "$THREAD" || exit $?
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" \
     [--topic "$TOPIC"] [--oneshot] [--model "$MODEL"] [--effort "$EFFORT"] \
     <<< "$PROMPT"
   ```

4. Show findings and the exact verdict; link the full log. Validate objections before revising the plan. If a
   claim is wrong, refute it with evidence rather than reshaping the plan around
   it. Stop paid iteration at `APPROVE`, optional-only `COMMENT`, or the authorized cap.
   New blocking classes call for systemic replanning, not an automatic user question.
   In an owning workflow return findings and let it continue the task.

5. On a non-zero exit, act per the Exit codes table of the skill `codex-triage`.
