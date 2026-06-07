---
description: Send code, a diff, a PR, or another agent's findings to the persistent "review" Codex thread for critique. Supports focus lenses.
argument-hint: [--lens <name>] [--oneshot] <paste or "review my branch">
allowed-tools: Bash
disable-model-invocation: true
---

# /codex-review

Forwards a review request to the Codex thread `review`, creating it on first use and resuming it on subsequent calls so Codex retains context. Codex fetches the diff and runs tests itself — send it the **intent** and **focus**, not the file contents.

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--lens <name>` → one of: `correctness` (default), `security`, `performance`, `architecture`, `ux`, `quick`.
   - `--oneshot` → pass through to the driver (throwaway, no thread kept).
   The remainder is the user's paste/focus.

2. Build the Codex prompt:
   - Read `references/review-lenses.md` (in this plugin's skill dir), take the block for the chosen lens plus the shared output contract, and use it as the INSTRUCTION.
   - State the SCOPE if the user implied one ("this branch", "uncommitted", "last commit") so Codex knows what to diff. If unstated, default to uncommitted + current branch vs its merge base.
   - **If the remainder is a third-party review/critique, apply Judge-mode framing per skill `codex-triage`** (classify, do not instruct Codex to apply fixes).

3. Run via Bash (timeout 600000 — reviews take minutes):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" review [--oneshot] <<< "$PROMPT_BODY"
   ```

4. Show Codex's reply verbatim.

5. Exit code 4 (resume failed) → ask the user before `--new`, per skill. Exit code 5 / porcelain warning → surface the diff (Codex touched files).

## Notes

- Lens templates: `references/review-lenses.md`. No `--lens` = `correctness`.
- Thread state: `.claude/codex-threads/review.id` / `.log`. Force-reset: `/codex-thread-new review`.
- For a one-off with no follow-up: `--oneshot`.
