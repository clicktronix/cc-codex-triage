---
description: Stress-test a plan or architecture decision in a persistent Codex thread. Iterates to APPROVE by default; use --once for one pass.
argument-hint: "[--lens <name>] [--thread <name>] [--topic <text>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] <plan or question>"
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/*)
disable-model-invocation: true
---

# /plan

Stress-test a plan, revise validated gaps, and resume until `APPROVE`, only
optional comments remain, or the round cap is reached.

## Steps

1. Parse leading flags. The default thread comes from
   `${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh plan`; default lens is
   `stress-test`; default cap is 5. `--once`, `--oneshot`, and `--background`
   are single-pass. A clearly different artifact needs a new thread.

2. Resolve state with `state-dir.sh`. On the initial dispatch, read the selected
   plan focus and output contract from
   `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md` and
   append the plan text or repo path. On resume, send only what changed and ask
   Codex to re-check its previous objections before finding new ones.

3. Dispatch:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" \
     [--topic "$TOPIC"] [--oneshot] [--model "$MODEL"] [--effort "$EFFORT"] \
     <<< "$PROMPT"
   ```

   Initial-only model and effort flags are ignored with a warning on resume.
   Exit 20 means the paid worker is still running; use the printed
   `detach-watch.sh` command instead of dispatching again. For `--background`,
   run this same wrapper as a Claude-managed background task; the wrapper owns
   worker isolation and watcher delivery, so do not add another detach layer.

4. Show the reply verbatim. Validate objections before revising the plan. If a
   claim is wrong, refute it with evidence rather than reshaping the plan around
   it. Stop at `APPROVE`, optional-only `COMMENT`, cap, or two rounds of new
   blocking classes that show the design itself is unfinished.

5. Exit 4 means resume failed: ask before resetting the thread. Exit 5 means
   Codex changed tracked files: show the diff and stop.
