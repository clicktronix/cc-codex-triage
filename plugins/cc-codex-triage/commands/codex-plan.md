---
description: Send a message to the persistent "plan" Codex thread; creates one if none exists. Use to discuss architecture, design docs, or implementation plans.
argument-hint: <plan, design doc, or architecture question>
allowed-tools: Bash
disable-model-invocation: true
---

# /codex-plan

Forwards `$ARGUMENTS` to the named Codex thread `plan`, creating it on first use and resuming on subsequent calls so Codex retains the full architecture context.

## Steps

1. Run via Bash tool (timeout 600000):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" plan <<< "$ARGUMENTS"
   ```

2. Show Codex's reply verbatim.

3. If the script exits with **code 4** (resume failed), do NOT auto-retry with `--new`. Ask the user whether to start fresh.

4. Surface any tracked-file mutation warnings (exit code 5).

## Notes

- The `plan` thread is for architecture discussions where context accumulates over many turns: "here's the plan" → Codex critiques → you revise → Codex re-evaluates against its prior critique.
- Thread state: `.claude/codex-threads/plan.id`; audit log `.claude/codex-threads/plan.log`.
- Force-reset: `/codex-thread-new plan`.
