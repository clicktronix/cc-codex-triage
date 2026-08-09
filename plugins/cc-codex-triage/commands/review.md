---
description: Run a persistent Codex code-review loop. Use --required for an owning delivery workflow that must obtain APPROVE on an exact clean candidate; otherwise iterates to APPROVE as an advisory review.
argument-hint: '[--required --base <ref> --spec <path>] [--lens <name>] [--thread <name>] [--topic <text>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] [--json] <paste or "review my branch">'
allowed-tools: Bash
---

# /review

Forwards a review request to a Codex review thread. Advisory mode **iterates to APPROVE by default** — dispatch → address blocking findings → re-review — until Codex approves or a round cap. Required mode runs one machine-attributed review round per owning-workflow invocation; only that workflow may perform the fix/test/commit transition. Codex fetches the diff and runs tests itself — send it the **intent** and **focus**, not the file contents.

`--required` is the machine-enforced contract for an owning workflow such as `cc-tuner:run`: it accepts only a clean candidate commit, runs in the foreground, and writes an approval bound to the exact HEAD, tree and content fingerprint. A background/single-pass/Judge/JSON/oneshot review is useful evidence but can never satisfy this gate.

## Steps

1. Parse flags from the front of `$ARGUMENTS`:
   - `--required` → required delivery gate. It requires both `--base <ref>` (the integration baseline) and `--spec <repo-relative-path>` (the tracked delivery spec). Reject combinations with `--once`, `--oneshot`, `--background`, `--json`, or Judge mode: none can run the required foreground gate round. A required review must start from a clean candidate commit. The user's invocation of an owning `--auto` workflow authorizes the bounded required claims up to `--cap`; do not ask again per round.
   - `--base <ref>` / `--spec <path>` → required-review scope. Resolve the base to a commit and keep the tracked spec path repo-relative using `[a-zA-Z0-9_./-]`; do not infer or silently replace either.
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
   Store parsed values in shell variables and validated argument arrays. Every Bash example below
   passes those values as quoted data; never replace an angle-bracket token with raw spec/ref/prompt
   text or build a command with `eval`, `bash -c`, or textual concatenation.

2. **Judge-mode short-circuit (#19):** if the remainder is a **third-party review/critique** (another agent's findings — detection rules in skill `codex-triage`), run a **single classification pass — no loop** — and tell the user "Judge-mode: one classification pass, no iterate-loop." Apply Judge-mode framing (classify each finding valid / borderline / invalid / outdated; do **not** instruct Codex to apply fixes). Then skip the loop (step 9). If `--required` was also passed, reject the invocation instead: Judge-mode is advisory and can never satisfy the required gate.

3. Resolve shared state, then decide **initial vs resume**. State lives under the repository's common Git directory so it survives disposable-worktree cleanup:

   ```bash
   STATE_DIR=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/state-dir.sh") || exit $?
   ```

   It is a resume if `$STATE_DIR/<THREAD>.id` exists. Do NOT hand-compute a round number — the driver stamps `round=N` in the log header.

   For advisory mode, fail before any paid dispatch if the chosen thread owns required-review state.
   Required and advisory passes use dedicated thread names so advisory evidence can never overwrite or
   become trapped behind a completed delivery gate:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" advisory-check "$THREAD" || exit $?
   ```

   For `--required`, before every paid dispatch (including every post-fix round), capture the exact clean candidate. This also invalidates any previous approval until the new round earns one:

   ```bash
   BEGIN_RESULT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" begin "$THREAD" \
     --base "$BASE" --spec "$SPEC_PATH" --cap "$CAP") || exit $?
   CLAIM_TOKEN="${BEGIN_RESULT##* claim=}"
   CLAIM_TOKEN="${CLAIM_TOKEN%% *}"
   case "$CLAIM_TOKEN" in ''|*[!0-9a-f]*) echo "invalid required-review claim" >&2; exit 10 ;; esac
   ```

   Exit 13 is a hard stop: commit the fully tested candidate or clean the scope first. Do not downgrade to an advisory review.

4. Build the Codex prompt:
   - **Required dispatch:** prepend these exact machine-attributable lines using values from `<THREAD>.candidate`, followed by the ordinary intent/lens prompt. Do not paraphrase or omit them:

     ```text
     REQUIRED_REVIEW
     BASE_SHA: <canonical base SHA>
     CANDIDATE_SHA: <candidate HEAD>
     SPEC_PATH: <repo-relative spec path>
     ```

     Tell Codex to review the complete `<base>...<candidate>` change and read the spec as the acceptance contract.
   - **Initial dispatch only:** read the lens templates at `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`, and assemble the INSTRUCTION from the chosen lens's `<task>` block PLUS every block named on its `Include blocks:` line (each defined once in the file's `## Reusable prompt blocks` library) — `<output_contract>` is what carries the required `file:line` citation and `APPROVE | REQUEST_CHANGES | COMMENT` verdict, so it must not be dropped. **On a resume the thread already holds the lens contract — do NOT re-paste it;** send only the follow-up header, any scope change, and what changed since the last round. If `--json`: assemble the prompt with `<json_output_contract>` in place of `<output_contract>` (never both).
   - State the SCOPE if implied ("this branch", "uncommitted", "last commit"); else default to uncommitted + current branch vs its merge base. When scope is uncommitted, **explicitly include untracked new files** — they are NOT in `git diff HEAD`; tell Codex to also read `git status --porcelain -uall` and `cat` the new files.
   - **Resume only:** prepend the follow-up header (no hand-written round number): `This is a follow-up review round. Re-check your prior findings first (resolved / partial / not addressed), then new issues. State explicitly how close this is to APPROVE — if only minor or single-edge-case items remain, say so.`

5. **If `--json`: PREFLIGHT before dispatch** — run BOTH checks: (a) `command -v jq >/dev/null 2>&1` (step 6 needs `jq` to parse the reply); (b) `codex exec --help 2>/dev/null | grep -q -- '--output-schema'` (the driver needs codex ≥ 0.142 for structured output — an older CLI rejects `--output-schema` and the dispatch fails generically). If **either** check fails, tell the user what `--json` requires — `jq`, and/or Codex ≥ 0.142 (`codex --version`; upgrade via `npm install -g @openai/codex`) — and STOP, do not dispatch (a paid call whose reply can't be parsed, or that a stale Codex rejects, is worse than not sending it).

   **If `--background`:** launch the driver detached — run the SAME command below with the driver's `--detach` flag added, as a normal FOREGROUND Bash call: it prints `DETACHED pid=<pid> output=<THREAD>.detach-output log-offset=<B>` and returns instantly, while the dispatch keeps running in its own session (immune to harness process-reaping). **Then wire up completion delivery — the detached worker alone cannot notify you** (and a post-READY failure appends NO new `round=` header, so log polling would never fire): parse the PID and log offset into validated variables and launch the bundled watcher as a Claude-managed background task, `Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/detach-watch.sh" "$THREAD" "$PID" "$LOG_OFFSET", run_in_background: true)` — its completion notification carries the reply plus any worker warnings from `$THREAD.detach-stderr` (exit 0), the failure diagnostics — worker rc, `$THREAD.last-error.jsonl`, `detach-stderr`, `detach-output` tails (exit 1), a still-running timeout notice (exit 3), or an UNKNOWN outcome when no status record matches the worker PID (exit 4 — treat as failure until verified). The watcher is disposable: if the harness reaps it the worker is unaffected — fall back to polling `$STATE_DIR/$THREAD.log` for the next `round=` header (raw child output: `$THREAD.detach-output`, latest run only). Tell the user: "Codex review started in the background — the watcher will surface the result." Fallback if `--detach` exits 8 (neither `setsid` nor `python3` on PATH): `Bash(..., run_in_background: true)` on the plain command — with the caveat that the harness may reap the process group before Codex finishes. Do NOT enter the iterate loop (step 9) and do NOT poll this turn.

   Otherwise, run via Bash (the 600000 ms ceiling still applies to THIS call, not to the dispatch). For `--required`, set `CC_CODEX_TRIAGE_STRICT=1`; a reviewer mutation is a failed/stale round, not reviewed code:

   ```bash
   # --required
   CC_CODEX_TRIAGE_STRICT=1 bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" \
     "$THREAD" "${DISPATCH_ARGS[@]}" <<< "$PROMPT_BODY"

   # advisory
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" \
     "$THREAD" "${DISPATCH_ARGS[@]}" <<< "$PROMPT_BODY"
   ```

   `dispatch.sh` detaches the worker and then waits for it here, bounded below
   the caller's ceiling. A short dispatch returns the reply in this turn exactly
   as a direct call would; one that outruns the window **exits 20 and hands off**
   — the worker is untouched, and re-running the `detach-watch.sh` line it prints
   as a background task delivers the reply. Never treat exit 20 as a failure: the
   dispatch is still running and is already paid for.

   `begin` returns an invocation token and charges one bounded attempt. The
   token owns this exact round until `record` completes. If dispatch exits
   nonzero before appending a completed log record and no worker is still
   running, release the claim explicitly before returning; never call `begin`
   again over `PENDING` state:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" abort "$THREAD" \
     "$FAILURE_KIND" "$CLAIM_TOKEN"
   ```

   Exit 20 is a live handoff, not a failure: keep the claim and call `record`
   only after the watcher confirms that dispatch completed. Exit 5 is also a
   completed, logged pass: do not `abort` it; record it so candidate mutation
   becomes `STALE` evidence.

   If `--json`: also pass `--schema "${CLAUDE_PLUGIN_ROOT}/schemas/review-output.schema.json"` to the driver.

6. **If `--json`:** a single structured pass (implies `--once`). **On a `--json` resume, DO re-send `<json_output_contract>` in the prompt** — an explicit exception to the normal "resume doesn't re-paste the lens contract" rule, because earlier rounds on this thread were text-mode and never saw the JSON contract. Codex's reply is JSON — do NOT show it raw:
   1. `jq -e . <<<"$REPLY"` to confirm it parsed; on failure, show the raw reply and stop.
   2. Render a human view: verdict line, then findings sorted by severity then descending confidence, each as `[severity, conf] file:line — title` + body.
   3. For each finding, record it: `ledger.sh create <THREAD> --file <file> --line <line_start> --severity <severity> --title <title> --confidence <confidence>`.
   4. If `<THREAD>` is the current worktree's armed autoreview thread (`$GATE_DIR/autoreview.armed`, resolved with `gate-dir.sh`, names it), WARN: a `--json` pass is paid but cannot release the text-verdict gate — use text-mode `/review` for the gate.

7. Show Codex's reply verbatim (except `--json` — rendered per step 6 instead). Exit code 4 (resume failed) → ask the user before `--new`, per skill. Exit code 5 / porcelain warning → surface the diff (Codex touched files).

   Record every completed pass. Background is deliberately recorded as non-gating; a required foreground pass is accepted only when its verdict can be attributed to the unchanged candidate captured in step 3:

   ```bash
   # required foreground round
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" record \
     "$THREAD" foreground "$CLAIM_TOKEN"

   # advisory/background round (never gate-eligible)
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" record \
     "$THREAD" "$REVIEW_MODE"
   ```

   Results are machine-readable in `<THREAD>.review-state`: `APPROVED` is the only gate-eligible status. `REQUEST_CHANGES`, `NO_DECISION`, `STALE`, and `BACKGROUND_SINGLE_PASS` cannot be treated as completion. On final `APPROVE`, self-verify from this command's plugin root:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" check "$THREAD"
   ```

   Make its successful stdout the final line returned by this command, verbatim:

   ```text
   CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<sha> tree=<sha> fingerprint=<sha> base_sha=<sha> spec_path=<path>
   ```

   The owning workflow must require this exact marker and compare `head` to its candidate HEAD. It must not guess this plugin's root after control returns: `${CLAUDE_PLUGIN_ROOT}` then belongs to the owning plugin. Any nonzero check or missing/mismatched marker means no approval.

8. **Validate each finding against the code** — per the skill's "validating inbound Codex findings" rule. Read the cited site *and its consumers*, check for a documented reason the current code stands, confirm the suggested fix would not regress, and classify each finding valid / borderline / invalid / outdated. Reject invalid/outdated ones via `/reply <THREAD>` (pass the SAME thread explicitly — `/reply`'s default is `review-<branch-slug>`, aligned with this command's, but an explicit name is still safer when several review threads exist) with the concrete file:line that refutes them; surface borderline/architectural ones to the user. **Never apply a finding you believe is wrong just to reach APPROVE.**

   In `--required` mode, stop here on every `REQUEST_CHANGES`: do not edit files, stage, commit, or run a repair loop inside this command. Return the validated findings without an approval marker. The owning workflow must enter its explicit fix transition, implement, test, commit a new candidate, and invoke this same required thread again. This separation is mandatory even when the fix looks trivial.

   In advisory mode only, apply the valid findings and **fix the neighborhood** (every site of the flagged class, not just the cited line — say which sites you covered in the next round).

9. **Iterate advisory review to APPROVE (default advisory behavior — skipped for `--required`, `--once`, `--oneshot`, `--json`, `--background`, and Judge-mode):** if the last verdict is `REQUEST_CHANGES` and you have now addressed its blocking findings, go back to step 4 (resume) and re-review, stating which sites you fixed. Repeat until one of:
   - **APPROVE** → done.
   - **only `(non-blocking)`/`(if-minor)` items remain** → done; report them, do not loop on nitpicks (the verdict contract already keeps those out of `REQUEST_CHANGES`).
   - **`--cap` rounds reached** → run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" stop "$THREAD" cap`, report the open findings, and hard-stop. Cap bounds spend; it never grants approval or permits merge.
   - **the loop is diverging** → two rounds running whose blocking findings are entirely NEW classes, with nothing carried over from the previous round. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" stop "$THREAD" divergence` and hard-stop for a user decision: back to `/plan`, or cut the scope. Per skill `codex-triage` ("when the review loop is the wrong tool") — the design is being discovered through review at one paid dispatch per decision. Judge by repeat structure, not round count: a long thread whose blocking count is falling and whose findings are repairs of earlier ones is converging and must not be interrupted.
   A finding you've refuted with file:line is resolved; if Codex still holds it, **escalate to the user** (they lower the bar or accept the open item) — do not fix a wrong finding just to release.

## Findings ledger (machine-readable history, needs `jq`)

The ledger lets `--continue` and `/review-dispute|accept|defer` work from state instead of prose. If `jq` is absent, skip it — the review still works.

- **Record findings** as you validate them (step 8; for `--json`, step 6.3 records each finding directly from the parsed reply, with `--confidence`). Let the helper allocate the id:
  ```bash
  id=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" create "$THREAD" \
    --file "$FINDING_FILE" --line "$FINDING_LINE" --severity "$SEVERITY" \
    --label issue --title "$FINDING_TITLE" "${CONFIDENCE_ARGS[@]}")
  ```
  When you resolve/reject/defer a finding from a prior round, append a status event by its id:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" status "$THREAD" "$FINDING_ID" "$FINDING_STATUS" "${NOTE_ARGS[@]}"
  ```
  Render the user-visible summary from `ledger.sh list <THREAD>` — so what they see is exactly what was recorded.
- **Pin the scope once (#9)** — after the FIRST *successful* dispatch (the thread now has a `.id`, so a failed dispatch leaves no orphan sidecar), record the **same base/mode you actually sent Codex this round**, and on later rounds READ it back instead of re-deriving. Do **not** hardcode `@{u}` as the base: on a pushed branch the upstream merge-base is only the *last push*, so a resume would silently narrow the diff to "since I pushed" and omit the rest of the branch. Pin the integration-branch merge-base (the base the review is actually against):
  ```bash
  # write once, on the first successful dispatch. TRUNK = the branch you reviewed
  # against; REVIEW_MODE = the scope you used ("branch-vs-<trunk>",
  # "uncommitted+untracked", "<sha>..HEAD", ...) — record what you actually sent.
  TRUNK="$(git rev-parse --verify -q main >/dev/null 2>&1 && echo main || echo master)"
  base="$(git merge-base HEAD "$TRUNK" 2>/dev/null || git rev-parse HEAD)"
  STATE_DIR=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/state-dir.sh") || exit $?
  printf 'base=%s\nmode=%s\n' "$base" "$REVIEW_MODE" > "$STATE_DIR/$THREAD.scope"
  # reuse on resume instead of recomputing the base:
  base="$(sed -n 's/^base=//p' "$STATE_DIR/$THREAD.scope" 2>/dev/null)"
  mode="$(sed -n 's/^mode=//p' "$STATE_DIR/$THREAD.scope" 2>/dev/null)"
  ```
- **Record the approval baseline on APPROVE** via `review-state.sh record`, never by hand. The helper binds it to the candidate HEAD, tree and fingerprint and refuses a dirty, moved or unattributable candidate.
- **`--continue`**: if `$STATE_DIR/<THREAD>.approved` is **absent** (the thread never reached APPROVE), fall back to a resume scoped to the **pinned `.scope` base** (`<base>..HEAD` plus the uncommitted diff) — not just the current uncommitted diff, which would drop every already-committed round + still-open findings. Otherwise read `head="$(sed -n 's/^head=//p' "$STATE_DIR/<THREAD>.approved")"`: if HEAD has advanced since approval (committed work) scope to `<head>..HEAD`, else re-review the current uncommitted diff. Either way, prepend the still-open findings from `ledger.sh open <THREAD>`. This rebuilds the resume from state — no hand-narrated "what changed". (For uncommitted scope the since-approval boundary is approximate; the open-findings carry-forward is exact.)

## Notes

- Advisory mode **iterates** to APPROVE; required mode returns each blocking round to its owning lifecycle and emits a marker only after an exact-candidate approval. `--once` is for a single advisory opinion you act on yourself; `--oneshot` is ephemeral.
- `--cap` bounds advisory iterations or required pre-dispatch claims across owning-workflow invocations. A required claim consumes budget before launch, conservatively, so failed or UUID-less paid calls cannot bypass the cap. The `/autoreview` gate has a **separate** cap that counts hook-blocks (each block runs `/review --once`, not a loop) — see `autoreview.md`.
- Lens templates: `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`. No `--lens` = `correctness`.
- Thread state: the common Git directory reported by `state-dir.sh`, shared by all worktrees. Force-reset: `/thread-new <thread>`.
- Required gate state: `<thread>.candidate`, `<thread>.review-state`, and `<thread>.approved`. Only `review-state.sh check <thread>` is authoritative; prose, a board issue, an old APPROVE, or a single background pass is not.
- The `/autoreview` gate always dispatches text-mode `/review --once` — never `--json`. The hook's verdict parser (`scripts/last-verdict.sh`, shared with `/status`) reads a verdict standing alone on its own line in a text-mode reply — heading marks and bold around it are tolerated, a line carrying other words is not. A verdict embedded in JSON is not on such a line, so a `--json` pass can neither release nor false-release the gate; use text-mode `/review` for the gate, and `--json` for a separate structured-output request (step 6).
