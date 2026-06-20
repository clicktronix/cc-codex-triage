---
description: Send a plan, design doc, or architecture question to a persistent Codex plan thread to stress-test it. Supports focus lenses and per-task threads.
argument-hint: "[--lens <name>] [--thread <name>] [--oneshot] <plan or architecture question>"
allowed-tools: Bash
disable-model-invocation: true
---

# /plan

Forwards a planning prompt to a Codex plan thread, creating it on first use and resuming on subsequent calls so Codex retains the full design context across turns ("here's the plan" → critique → you revise → Codex re-evaluates against its own prior critique).

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--lens <name>` → one of: `stress-test` (default), `pre-mortem`, `devils-advocate`, `alternatives`, `adr`.
   - `--thread <name>` → target thread (default `plan`). **Planning a NEW task while `plan` already holds a different one? Use a per-task thread (`plan-<topic>`)** — a production run that mixed two features in one `plan` thread paid every later round's resume cost re-feeding the first feature's full history.
   - `--oneshot` → pass through to the driver.
   The remainder is the plan text or a pointer to it (e.g. a `docs/plans/*.md` path Codex should read).

2. Decide **initial vs resume** (state lives at the repo root — `cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"` first if your cwd drifted): it is a **resume** if `.claude/codex-threads/<THREAD>.id` exists, otherwise **initial**. Do NOT hand-compute a round number into the prompt — the driver stamps `round=N` in the log header itself.

3. Build the Codex prompt:
   - **Initial dispatch only:** read the lens templates at `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`, take the plan block for the chosen lens (plus the exhaustive-instances + verdict block), use it as the INSTRUCTION, and include the plan text (or tell Codex which file to read). **On a resume the thread already holds the lens instruction — do NOT re-paste it;** point Codex at the revised plan (which file to re-read / what changed) and send only the follow-up header.
   - **Resume only:** prepend (no hand-written round number): `This is a follow-up round. Re-evaluate against your OWN prior objections first (resolved / partial / not addressed), then new ones. State explicitly how close the plan is to APPROVE.`

4. Run via Bash (timeout 600000):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> [--oneshot] <<< "$PROMPT_BODY"
   ```

5. Show Codex's reply verbatim.

6. Exit code 4 (resume failed) → ask the user before `--new`. Exit code 5 → surface the diff.

## Notes

- Lens templates: `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`. No `--lens` = `stress-test`.
- Thread state: `.claude/codex-threads/<thread>.{id,log,rounds}`. Force-reset: `/thread-new <thread>`.
- For a one-off: `--oneshot`.
