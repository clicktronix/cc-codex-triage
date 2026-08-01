---
description: Send a plan, design doc, or architecture question to a persistent Codex plan thread to stress-test it. Iterates to APPROVE by default; --once for a single pass. Supports focus lenses and per-task threads.
argument-hint: "[--lens <name>] [--thread <name>] [--topic <text>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] <plan or architecture question>"
allowed-tools: Bash
disable-model-invocation: true
---

# /plan

Forwards a planning prompt to a Codex plan thread and **iterates to APPROVE by default** — stress-test → revise the plan → re-stress — until the plan is sound (APPROVE) or a round cap. Codex retains the full design context across rounds.

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--lens <name>` → one of: `stress-test` (default), `pre-mortem`, `devils-advocate`, `alternatives`, `adr`.
   - `--thread <name>` → target thread. **Default: `plan-<branch-slug>`** (e.g. `plan-main` on `main` — no main/master special-case; the bare `plan` thread only via an explicit `--thread`). `<branch-slug>` = the current branch with every character outside `[a-zA-Z0-9_.-]` replaced by `-` — the same slug rule the hook and `/autoplan` use. Per-task threads keep one task per thread.
   - `--once` → a single stress-test pass, no iterate-loop.
   - `--topic <text>` → one-line label recorded when the thread is CREATED, so `/thread-list` and a later agent can tell what it holds. Ignored on an existing thread.
   - `--oneshot` → throwaway ephemeral run. Implies `--once`.
   - `--cap N` → max rounds in the loop (default 5).
   - `--model <m>` / `--effort <none|minimal|low|medium|high|xhigh>` → forwarded to the driver, which applies them on initial/oneshot dispatch only (a resume keeps the thread's model/effort stable and WARNs if you pass them again — use `--new` to change them).
   - `--background` → launch the driver detached and return this turn without waiting; implies a single pass — no iterate loop (step 6), same as `--once`. Preferred mechanism: the driver's own `--detach` flag plus the bundled `detach-watch.sh` watcher run as a Claude-managed background task for completion delivery (details in step 4). Fallback: `Bash(..., run_in_background: true)` — works, but the harness may reap the process group before Codex finishes.
   The remainder is the plan text or a pointer to it (e.g. a `docs/plans/*.md` path Codex should read).
   - **Reuse guard (#8):** if the chosen thread already holds a clearly different plan/artifact, warn the user and suggest a fresh `--thread plan-<topic>` — one task = one thread (a thread reused across artifacts pays to re-feed the old context every round and muddies round semantics).

2. Decide **initial vs resume**: it is a resume if `.claude/codex-threads/<THREAD>.id` exists (state lives at the repo root — `cd "$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)"` first if your cwd drifted). Do NOT hand-compute a round number — the driver stamps `round=N` in the log header.

3. Build the Codex prompt:
   - **Initial dispatch only:** read the lens templates at `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`, and assemble the INSTRUCTION from the chosen plan lens's `<task>` block PLUS every block named on its `Include blocks:` line (each defined once in the file's `## Reusable prompt blocks` library — includes `<plan_verdict>`, the exhaustive-instances + machine-verdict contract), then include the plan text (or tell Codex which file to read). **On a resume the thread already holds the lens instruction — do NOT re-paste it;** point Codex at the revised plan (which file to re-read / what changed) and send only the follow-up header.
   - **Resume only:** prepend (no hand-written round number): `This is a follow-up round. Re-evaluate against your OWN prior objections first (resolved / partial / not addressed), then new ones. State explicitly how close the plan is to APPROVE.`

4. **If `--background`:** launch the driver detached — run the SAME command below with the driver's `--detach` flag added, as a normal FOREGROUND Bash call: it prints `DETACHED pid=<pid> output=<THREAD>.detach-output log-offset=<B>` and returns instantly, while the dispatch keeps running in its own session (immune to harness process-reaping). **Then wire up completion delivery — the detached worker alone cannot notify you** (and a post-READY failure appends NO new `round=` header, so log polling would never fire): parse `<pid>` and `<B>` from the DETACHED line and launch the bundled watcher as a Claude-managed background task, `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detach-watch.sh" <THREAD> <pid> <B>, run_in_background: true)` — its completion notification carries the reply plus any worker warnings from `<THREAD>.detach-stderr` (exit 0), the failure diagnostics — worker rc, `<THREAD>.last-error.jsonl`, `detach-stderr`, `detach-output` tails (exit 1), a still-running timeout notice (exit 3), or an UNKNOWN outcome when no status record matches the worker PID (exit 4 — treat as failure until verified). The watcher is disposable: if the harness reaps it the worker is unaffected — fall back to polling `.claude/codex-threads/<THREAD>.log` for the next `round=` header (raw child output: `<THREAD>.detach-output`, latest run only). Tell the user: "Codex plan review started in the background — the watcher will surface the result." Fallback if `--detach` exits 8 (neither `setsid` nor `python3` on PATH): `Bash(..., run_in_background: true)` on the plain command — with the caveat that the harness may reap the process group before Codex finishes. Do NOT enter the iterate loop (step 6) and do NOT poll this turn.

   Otherwise, run via Bash (timeout 600000):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> [--topic "<text>"] [--oneshot] [--model <m>] [--effort <e>] <<< "$PROMPT_BODY"
   ```

5. Show Codex's reply verbatim. Exit code 4 (resume failed) → ask the user before `--new`. Exit code 5 → surface the diff.

6. **Iterate to APPROVE (default — skipped for `--once`, `--oneshot`, `--background`):** if the verdict is `REQUEST_CHANGES`, revise the plan to address the blocking objections (validate them first — a plan objection can be wrong too), then go back to step 3 (resume) and re-stress, saying what you changed. Repeat until one of:
   - **APPROVE** → the plan is sound to execute; done.
   - **only minor/optional concerns remain** (`COMMENT`) → done; report them.
   - **`--cap` rounds reached** → stop and surface the open objections — do not keep looping.
   If an objection is wrong, refute it with evidence and escalate to the user rather than reshaping the plan around a bad objection.

## Notes

- Default **iterates** to APPROVE; `--once` for a single stress-test; `--oneshot` ephemeral.
- Lens templates: `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`. No `--lens` = `stress-test`.
- Thread state: `.claude/codex-threads/<thread>.{id,log,rounds}`. Force-reset: `/thread-new <thread>`.
