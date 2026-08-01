---
description: Send code, a diff, a PR, or another agent's findings to a persistent Codex review thread for critique. Iterates to APPROVE by default; --once for a single pass. Supports focus lenses and per-task threads.
argument-hint: '[--lens <name>] [--thread <name>] [--topic <text>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] [--json] <paste or "review my branch">'
allowed-tools: Bash
disable-model-invocation: true
---

# /review

Forwards a review request to a Codex review thread and **iterates to APPROVE by default** — dispatch → address blocking findings → re-review — until Codex approves or a round cap. Codex fetches the diff and runs tests itself — send it the **intent** and **focus**, not the file contents.

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--lens <name>` → one of: `correctness` (default), `security`, `performance`, `architecture`, `ux`, `quick`.
   - `--thread <name>` → target thread. **Default: `review-<branch-slug>`** (e.g. `review-main` on `main` — no main/master special-case; the bare `review` thread only via an explicit `--thread`). `<branch-slug>` = the current branch with every character outside `[a-zA-Z0-9_.-]` replaced by `-` — the SAME slug rule the hook and `/autoreview` use, so a manual review and the gate share one thread. Per-task threads keep one task per thread; mixing tasks inflates every later resume.
   - `--once` → a single dispatch, no iterate-loop (you decide after one round).
   - `--topic <text>` → one-line label recorded when the thread is CREATED, so `/thread-list` and a later agent can tell what it holds. Ignored on an existing thread.
   - `--oneshot` → throwaway ephemeral run (no thread kept). Implies `--once`.
   - `--cap N` → max review rounds in the loop (default 5).
   - `--model <m>` / `--effort <none|minimal|low|medium|high|xhigh>` → forwarded to the driver, which applies them on initial/oneshot dispatch only (a resume keeps the thread's model/effort stable and WARNs if you pass them again — use `--new` to change them).
   - `--continue` → resume from the last APPROVE: rebuild the prompt from the findings ledger (still-open findings) + the diff since the approved baseline, instead of re-authoring it. See **Findings ledger** below.
   - `--background` → launch the driver detached and return this turn without waiting; implies a single pass — no iterate loop (step 9), same as `--once`. Preferred mechanism: the driver's own `--detach` flag plus the bundled `detach-watch.sh` watcher run as a Claude-managed background task for completion delivery (details in step 5). Fallback: `Bash(..., run_in_background: true)` — works, but the harness may reap the process group before Codex finishes.
   - `--json` → structured output instead of Conventional Comments prose: a single pass (implies `--once`), needs codex ≥ 0.142 and `jq`. Works on an initial dispatch OR on an existing thread (resume) — see step 6. Composes with `--continue`: `--json --continue` is a single structured pass scoped to the continue-resume (still-open findings + diff since the approved baseline), not a full iterate-loop.
   The remainder is the user's paste/focus.
   - **Reuse guard (#8):** if the chosen thread already has a `.log` from a clearly different task (different feature/area than the current request), warn the user and suggest a fresh `--thread review-<topic>` — Codex would otherwise re-feed the old task's history every round.

2. **Judge-mode short-circuit (#19):** if the remainder is a **third-party review/critique** (another agent's findings — detection rules in skill `codex-triage`), run a **single classification pass — no loop, regardless of flags** — and tell the user "Judge-mode: one classification pass, no iterate-loop." Apply Judge-mode framing (classify each finding valid / borderline / invalid / outdated; do **not** instruct Codex to apply fixes). Then skip the loop (step 9).

3. Decide **initial vs resume**: it is a resume if `.claude/codex-threads/<THREAD>.id` exists (state lives at the repo root — `cd "$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)"` first if your cwd drifted). Do NOT hand-compute a round number — the driver stamps `round=N` in the log header.

4. Build the Codex prompt:
   - **Initial dispatch only:** read the lens templates at `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`, and assemble the INSTRUCTION from the chosen lens's `<task>` block PLUS every block named on its `Include blocks:` line (each defined once in the file's `## Reusable prompt blocks` library) — `<output_contract>` is what carries the required `file:line` citation and `APPROVE | REQUEST_CHANGES | COMMENT` verdict, so it must not be dropped. **On a resume the thread already holds the lens contract — do NOT re-paste it;** send only the follow-up header, any scope change, and what changed since the last round. If `--json`: assemble the prompt with `<json_output_contract>` in place of `<output_contract>` (never both).
   - State the SCOPE if implied ("this branch", "uncommitted", "last commit"); else default to uncommitted + current branch vs its merge base. When scope is uncommitted, **explicitly include untracked new files** — they are NOT in `git diff HEAD`; tell Codex to also read `git status --porcelain -uall` and `cat` the new files.
   - **Resume only:** prepend the follow-up header (no hand-written round number): `This is a follow-up review round. Re-check your prior findings first (resolved / partial / not addressed), then new issues. State explicitly how close this is to APPROVE — if only minor or single-edge-case items remain, say so.`

5. **If `--json`: PREFLIGHT before dispatch** — run BOTH checks: (a) `command -v jq >/dev/null 2>&1` (step 6 needs `jq` to parse the reply); (b) `codex exec --help 2>/dev/null | grep -q -- '--output-schema'` (the driver needs codex ≥ 0.142 for structured output — an older CLI rejects `--output-schema` and the dispatch fails generically). If **either** check fails, tell the user what `--json` requires — `jq`, and/or Codex ≥ 0.142 (`codex --version`; upgrade via `npm install -g @openai/codex`) — and STOP, do not dispatch (a paid call whose reply can't be parsed, or that a stale Codex rejects, is worse than not sending it).

   **If `--background`:** launch the driver detached — run the SAME command below with the driver's `--detach` flag added, as a normal FOREGROUND Bash call: it prints `DETACHED pid=<pid> output=<THREAD>.detach-output log-offset=<B>` and returns instantly, while the dispatch keeps running in its own session (immune to harness process-reaping). **Then wire up completion delivery — the detached worker alone cannot notify you** (and a post-READY failure appends NO new `round=` header, so log polling would never fire): parse `<pid>` and `<B>` from the DETACHED line and launch the bundled watcher as a Claude-managed background task, `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detach-watch.sh" <THREAD> <pid> <B>, run_in_background: true)` — its completion notification carries the reply plus any worker warnings from `<THREAD>.detach-stderr` (exit 0), the failure diagnostics — worker rc, `<THREAD>.last-error.jsonl`, `detach-stderr`, `detach-output` tails (exit 1), a still-running timeout notice (exit 3), or an UNKNOWN outcome when no status record matches the worker PID (exit 4 — treat as failure until verified). The watcher is disposable: if the harness reaps it the worker is unaffected — fall back to polling `.claude/codex-threads/<THREAD>.log` for the next `round=` header (raw child output: `<THREAD>.detach-output`, latest run only). Tell the user: "Codex review started in the background — the watcher will surface the result." Fallback if `--detach` exits 8 (neither `setsid` nor `python3` on PATH): `Bash(..., run_in_background: true)` on the plain command — with the caveat that the harness may reap the process group before Codex finishes. Do NOT enter the iterate loop (step 9) and do NOT poll this turn.

   Otherwise, run via Bash (the 600000 ms ceiling still applies to THIS call, not to the dispatch):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" <THREAD> [--topic "<text>"] [--oneshot] [--model <m>] [--effort <e>] [--schema <FILE>] <<< "$PROMPT_BODY"
   ```

   If `--json`: also pass `--schema "${CLAUDE_PLUGIN_ROOT}/schemas/review-output.schema.json"` to the driver.

6. **If `--json`:** a single structured pass (implies `--once`). **On a `--json` resume, DO re-send `<json_output_contract>` in the prompt** — an explicit exception to the normal "resume doesn't re-paste the lens contract" rule, because earlier rounds on this thread were text-mode and never saw the JSON contract. Codex's reply is JSON — do NOT show it raw:
   1. `jq -e . <<<"$REPLY"` to confirm it parsed; on failure, show the raw reply and stop.
   2. Render a human view: verdict line, then findings sorted by severity then descending confidence, each as `[severity, conf] file:line — title` + body.
   3. For each finding, record it: `ledger.sh create <THREAD> --file <file> --line <line_start> --severity <severity> --title <title> --confidence <confidence>`.
   4. If `<THREAD>` is the armed autoreview thread (`.claude/codex-threads/autoreview.armed` names it), WARN: a `--json` pass is paid but cannot release the text-verdict gate — use text-mode `/review` for the gate.

7. Show Codex's reply verbatim (except `--json` — rendered per step 6 instead). Exit code 4 (resume failed) → ask the user before `--new`, per skill. Exit code 5 / porcelain warning → surface the diff (Codex touched files).

8. **Validate each finding against the code before applying** — per the skill's "validating inbound Codex findings" rule. Read the cited site *and its consumers*, check for a documented reason the current code stands, confirm the suggested fix doesn't regress, and classify each finding valid / borderline / invalid / outdated. Apply only the valid ones, and **fix the neighborhood** (every site of the flagged class, not just the cited line — say which sites you covered in the next round). Reject invalid/outdated ones via `/reply <THREAD>` (pass the SAME thread explicitly — `/reply`'s default is `review-<branch-slug>`, aligned with this command's, but an explicit name is still safer when several review threads exist) with the concrete file:line that refutes them; surface borderline/architectural ones to the user. **Never apply a finding you believe is wrong just to reach APPROVE.**

9. **Iterate to APPROVE (default — skipped for `--once`, `--oneshot`, `--json`, `--background`, and Judge-mode):** if the last verdict is `REQUEST_CHANGES` and you have now addressed its blocking findings, go back to step 4 (resume) and re-review, stating which sites you fixed. Repeat until one of:
   - **APPROVE** → done.
   - **only `(non-blocking)`/`(if-minor)` items remain** → done; report them, do not loop on nitpicks (the verdict contract already keeps those out of `REQUEST_CHANGES`).
   - **`--cap` rounds reached** → stop and tell the user the open findings — do not keep looping.
   - **the loop is diverging** → two rounds running whose blocking findings are entirely NEW classes, with nothing carried over from the previous round. Stop and put it to the user: back to `/plan`, or cut the scope. Per skill `codex-triage` ("when the review loop is the wrong tool") — the design is being discovered through review at one paid dispatch per decision. Judge by repeat structure, not round count: a long thread whose blocking count is falling and whose findings are repairs of earlier ones is converging and must not be interrupted.
   A finding you've refuted with file:line is resolved; if Codex still holds it, **escalate to the user** (they lower the bar or accept the open item) — do not fix a wrong finding just to release.

## Findings ledger (machine-readable history, needs `jq`)

The ledger lets `--continue` and `/review-dispute|accept|defer` work from state instead of prose. If `jq` is absent, skip it — the review still works.

- **Record findings** as you validate them (step 8; for `--json`, step 6.3 records each finding directly from the parsed reply, with `--confidence`). Let the helper allocate the id:
  ```

   `dispatch.sh` detaches the worker and then waits for it here, bounded below
   the caller's ceiling. A short dispatch returns the reply in this turn exactly
   as a direct call would; one that outruns the window **exits 3 and hands off**
   — the worker is untouched, and re-running the `detach-watch.sh` line it prints
   as a background task delivers the reply. Never treat exit 3 as a failure: the
   dispatch is still running and is already paid for.
bash
  id=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" create <THREAD> --file F --line L --severity blocking|non-blocking --label issue --title "short title" [--confidence C])
  ```
  When you resolve/reject/defer a finding from a prior round, append a status event by its id:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" status <THREAD> <id> resolved|false-positive|accepted|deferred [--note "..."]
  ```
  Render the user-visible summary from `ledger.sh list <THREAD>` — so what they see is exactly what was recorded.
- **Pin the scope once (#9)** — after the FIRST *successful* dispatch (the thread now has a `.id`, so a failed dispatch leaves no orphan sidecar), record the **same base/mode you actually sent Codex this round**, and on later rounds READ it back instead of re-deriving. Do **not** hardcode `@{u}` as the base: on a pushed branch the upstream merge-base is only the *last push*, so a resume would silently narrow the diff to "since I pushed" and omit the rest of the branch. Pin the integration-branch merge-base (the base the review is actually against):
  ```bash
  # write once, on the first successful dispatch. TRUNK = the branch you reviewed
  # against; REVIEW_MODE = the scope you used ("branch-vs-<trunk>",
  # "uncommitted+untracked", "<sha>..HEAD", ...) — record what you actually sent.
  TRUNK="$(git rev-parse --verify -q main >/dev/null 2>&1 && echo main || echo master)"
  base="$(git merge-base HEAD "$TRUNK" 2>/dev/null || git rev-parse HEAD)"
  printf 'base=%s\nmode=%s\n' "$base" "$REVIEW_MODE" > .claude/codex-threads/<THREAD>.scope
  # reuse on resume instead of recomputing the base:
  base="$(sed -n 's/^base=//p' .claude/codex-threads/<THREAD>.scope 2>/dev/null)"
  mode="$(sed -n 's/^mode=//p' .claude/codex-threads/<THREAD>.scope 2>/dev/null)"
  ```
- **Record the approval baseline on APPROVE** — snapshot what was approved (after the dispatch, only on a real APPROVE):
  ```bash
  printf 'head=%s\nround=%s\nts=%s\n' "$(git rev-parse HEAD)" '<round>' "$(date -u +%FT%TZ)" > .claude/codex-threads/<THREAD>.approved
  ```
- **`--continue`**: if `.claude/codex-threads/<THREAD>.approved` is **absent** (the thread never reached APPROVE), fall back to a resume scoped to the **pinned `.scope` base** (`<base>..HEAD` plus the uncommitted diff) — not just the current uncommitted diff, which would drop every already-committed round + still-open findings. Otherwise read `head="$(sed -n 's/^head=//p' .claude/codex-threads/<THREAD>.approved)"`: if HEAD has advanced since approval (committed work) scope to `<head>..HEAD`, else re-review the current uncommitted diff. Either way, prepend the still-open findings from `ledger.sh open <THREAD>`. This rebuilds the resume from state — no hand-narrated "what changed". (For uncommitted scope the since-approval boundary is approximate; the open-findings carry-forward is exact.)

## Notes

- Default **iterates** to APPROVE; `--once` for a single opinion you act on yourself; `--oneshot` ephemeral.
- `--cap` here bounds *this command's* iterate-loop. The `/autoreview` gate has a **separate** cap that counts hook-blocks (each block runs `/review --once`, not a loop) — see `autoreview.md`.
- Lens templates: `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`. No `--lens` = `correctness`.
- Thread state: `.claude/codex-threads/<thread>.{id,log,rounds}`. Force-reset: `/thread-new <thread>`.
- The `/autoreview` gate always dispatches text-mode `/review --once` — never `--json`. The hook's verdict parser (`scripts/last-verdict.sh`, shared with `/status`) reads a verdict standing alone on its own line in a text-mode reply — heading marks and bold around it are tolerated, a line carrying other words is not. A verdict embedded in JSON is not on such a line, so a `--json` pass can neither release nor false-release the gate; use text-mode `/review` for the gate, and `--json` for a separate structured-output request (step 6).
