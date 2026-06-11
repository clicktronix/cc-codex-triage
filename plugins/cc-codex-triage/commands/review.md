---
description: Send code, a diff, a PR, or another agent's findings to a persistent Codex review thread for critique. Supports focus lenses and per-task threads.
argument-hint: '[--lens <name>] [--thread <name>] [--oneshot] <paste or "review my branch">'
allowed-tools: Bash
disable-model-invocation: true
---

# /review

Forwards a review request to a Codex review thread, creating it on first use and resuming it on subsequent calls so Codex retains context. Codex fetches the diff and runs tests itself — send it the **intent** and **focus**, not the file contents.

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--lens <name>` → one of: `correctness` (default), `security`, `performance`, `architecture`, `ux`, `quick`.
   - `--thread <name>` → target thread (default `review`). **Starting review of a NEW task/branch while `review` already holds a different task? Use a per-task thread (`review-<branch>`)** — mixing tasks in one thread inflates resume cost and muddies the audit trail.
   - `--oneshot` → pass through to the driver (throwaway, no thread kept).
   The remainder is the user's paste/focus.

2. Read the round counter: `N=$(cat .claude/codex-threads/<THREAD>.rounds 2>/dev/null || echo 0)`. This dispatch is round `N+1`.

3. Build the Codex prompt:
   - Read `references/review-lenses.md` (in this plugin's skill dir), take the block for the chosen lens plus the shared output contract, and use it as the INSTRUCTION.
   - State the SCOPE if the user implied one ("this branch", "uncommitted", "last commit") so Codex knows what to diff. If unstated, default to uncommitted + current branch vs its merge base.
   - If `N >= 1`, prepend the convergence header: `This is round N+1 of this review. Re-check your prior findings first (resolved / partial / not addressed), then new issues. State explicitly how close this is to APPROVE — if only minor or single-edge-case items remain, say so.`
   - **If the remainder is a third-party review/critique, apply Judge-mode framing per skill `codex-triage`** (classify, do not instruct Codex to apply fixes).

4. Run via Bash (timeout 600000 — reviews take minutes):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> [--oneshot] <<< "$PROMPT_BODY"
   ```

5. Show Codex's reply verbatim.

6. Exit code 4 (resume failed) → ask the user before `--new`, per skill. Exit code 5 / porcelain warning → surface the diff (Codex touched files).

7. **Before applying anything, validate each finding against the code** — per the skill's **"validating inbound Codex findings"** rule. Read the cited site *and its consumers*, check for a documented reason the current code stands, confirm the suggested fix doesn't regress, and classify each finding valid / borderline / invalid / outdated. Apply only the valid ones; reject invalid/outdated ones via `/reply` with the concrete file:line that refutes them; surface borderline/architectural ones to the user. Do not apply a finding you believe is wrong just to release the `/autoreview` gate.

8. When applying the **valid** findings, follow the skill's **"fix the neighborhood"** rule — fix every site of the flagged problem class, not just the cited line, and say which sites you covered in the next round's prompt.

## Notes

- Lens templates: `references/review-lenses.md`. No `--lens` = `correctness`.
- Thread state: `.claude/codex-threads/<thread>.{id,log,rounds}`. Force-reset: `/thread-new <thread>`.
- For a one-off with no follow-up: `--oneshot`.
