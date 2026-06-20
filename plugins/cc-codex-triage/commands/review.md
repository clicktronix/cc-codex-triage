---
description: Send code, a diff, a PR, or another agent's findings to a persistent Codex review thread for critique. Iterates to APPROVE by default; --once for a single pass. Supports focus lenses and per-task threads.
argument-hint: '[--lens <name>] [--thread <name>] [--once] [--oneshot] [--cap N] <paste or "review my branch">'
allowed-tools: Bash
disable-model-invocation: true
---

# /review

Forwards a review request to a Codex review thread and **iterates to APPROVE by default** — dispatch → address blocking findings → re-review — until Codex approves or a round cap. Codex fetches the diff and runs tests itself — send it the **intent** and **focus**, not the file contents.

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--lens <name>` → one of: `correctness` (default), `security`, `performance`, `architecture`, `ux`, `quick`.
   - `--thread <name>` → target thread. **Default: `review-<branch-slug>` when the branch is not `main`/`master`, else `review`.** `<branch-slug>` = the current branch with every character outside `[a-zA-Z0-9_.-]` replaced by `-` (same slug rule the hook uses). Per-task threads keep one task per thread; mixing tasks inflates every later resume.
   - `--once` → a single dispatch, no iterate-loop (you decide after one round).
   - `--oneshot` → throwaway ephemeral run (no thread kept). Implies `--once`.
   - `--cap N` → max review rounds in the loop (default 5).
   The remainder is the user's paste/focus.
   - **Reuse guard (#8):** if the chosen thread already has a `.log` from a clearly different task (different feature/area than the current request), warn the user and suggest a fresh `--thread review-<topic>` — Codex would otherwise re-feed the old task's history every round.

2. **Judge-mode short-circuit (#19):** if the remainder is a **third-party review/critique** (another agent's findings — detection rules in skill `codex-triage`), run a **single classification pass — no loop, regardless of flags** — and tell the user "Judge-mode: one classification pass, no iterate-loop." Apply Judge-mode framing (classify each finding valid / borderline / invalid / outdated; do **not** instruct Codex to apply fixes). Then skip the loop (step 8).

3. Decide **initial vs resume**: it is a resume if `.claude/codex-threads/<THREAD>.id` exists (state lives at the repo root — `cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"` first if your cwd drifted). Do NOT hand-compute a round number — the driver stamps `round=N` in the log header.

4. Build the Codex prompt:
   - **Initial dispatch only:** read the lens templates at `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`, take the block for the chosen lens plus the shared output contract, and use it as the INSTRUCTION. **On a resume the thread already holds the lens contract — do NOT re-paste it;** send only the follow-up header, any scope change, and what changed since the last round.
   - State the SCOPE if implied ("this branch", "uncommitted", "last commit"); else default to uncommitted + current branch vs its merge base. When scope is uncommitted, **explicitly include untracked new files** — they are NOT in `git diff HEAD`; tell Codex to also read `git status --porcelain -uall` and `cat` the new files.
   - **Resume only:** prepend the follow-up header (no hand-written round number): `This is a follow-up review round. Re-check your prior findings first (resolved / partial / not addressed), then new issues. State explicitly how close this is to APPROVE — if only minor or single-edge-case items remain, say so.`

5. Run via Bash (timeout 600000 — reviews take minutes):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> [--oneshot] <<< "$PROMPT_BODY"
   ```

6. Show Codex's reply verbatim. Exit code 4 (resume failed) → ask the user before `--new`, per skill. Exit code 5 / porcelain warning → surface the diff (Codex touched files).

7. **Validate each finding against the code before applying** — per the skill's "validating inbound Codex findings" rule. Read the cited site *and its consumers*, check for a documented reason the current code stands, confirm the suggested fix doesn't regress, and classify each finding valid / borderline / invalid / outdated. Apply only the valid ones, and **fix the neighborhood** (every site of the flagged class, not just the cited line — say which sites you covered in the next round). Reject invalid/outdated ones via `/reply <THREAD>` (pass the SAME thread — `/reply`'s default is the bare `review`, which is the wrong thread on a feature branch) with the concrete file:line that refutes them; surface borderline/architectural ones to the user. **Never apply a finding you believe is wrong just to reach APPROVE.**

8. **Iterate to APPROVE (default — skipped for `--once`, `--oneshot`, and Judge-mode):** if the last verdict is `REQUEST_CHANGES` and you have now addressed its blocking findings, go back to step 4 (resume) and re-review, stating which sites you fixed. Repeat until one of:
   - **APPROVE** → done.
   - **only `(non-blocking)`/`(if-minor)` items remain** → done; report them, do not loop on nitpicks (the verdict contract already keeps those out of `REQUEST_CHANGES`).
   - **`--cap` rounds reached** → stop and tell the user the open findings — do not keep looping.
   A finding you've refuted with file:line is resolved; if Codex still holds it, **escalate to the user** (they lower the bar or accept the open item) — do not fix a wrong finding just to release.

## Notes

- Default **iterates** to APPROVE; `--once` for a single opinion you act on yourself; `--oneshot` ephemeral.
- `--cap` here bounds *this command's* iterate-loop. The `/autoreview` gate has a **separate** cap that counts hook-blocks (each block runs `/review --once`, not a loop) — see `autoreview.md`.
- Lens templates: `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`. No `--lens` = `correctness`.
- Thread state: `.claude/codex-threads/<thread>.{id,log,rounds}`. Force-reset: `/thread-new <thread>`.
