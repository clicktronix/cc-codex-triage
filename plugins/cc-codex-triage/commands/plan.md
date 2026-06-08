---
description: Send a plan, design doc, or architecture question to the persistent "plan" Codex thread to stress-test it. Supports focus lenses.
argument-hint: "[--lens <name>] [--oneshot] <plan or architecture question>"
allowed-tools: Bash
disable-model-invocation: true
---

# /plan

Forwards a planning prompt to the Codex thread `plan`, creating it on first use and resuming on subsequent calls so Codex retains the full design context across turns ("here's the plan" → critique → you revise → Codex re-evaluates against its own prior critique).

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--lens <name>` → one of: `stress-test` (default), `pre-mortem`, `devils-advocate`, `alternatives`, `adr`.
   - `--oneshot` → pass through to the driver.
   The remainder is the plan text or a pointer to it (e.g. a `docs/plans/*.md` path Codex should read).

2. Build the Codex prompt: read `references/review-lenses.md`, take the plan block for the chosen lens, use it as the INSTRUCTION. Include the plan text (or tell Codex which file to read).

3. Run via Bash (timeout 600000):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" plan [--oneshot] <<< "$PROMPT_BODY"
   ```

4. Show Codex's reply verbatim.

5. Exit code 4 (resume failed) → ask the user before `--new`. Exit code 5 → surface the diff.

## Notes

- Lens templates: `references/review-lenses.md`. No `--lens` = `stress-test`.
- Thread state: `.claude/codex-threads/plan.id` / `.log`. Force-reset: `/thread-new plan`.
- For a one-off: `--oneshot`.
