---
name: codex-triage
description: Use when the user wants to involve OpenAI Codex CLI from Claude Code — asking it a question, getting a second opinion on code or a plan, validating another agent's findings, or replying to something Codex said — especially across multiple turns of the same conversation.
---

# Codex Triage

## When to invoke

- The user types any plugin command: `/ask`, `/review`, `/plan`, `/reply`, `/debate`, `/status`, `/thread <name>`, `/thread-list`, `/thread-new`, `/cleanup`, `/review-dispute`, `/review-accept`, `/review-defer`, `/autoreview`, `/autoplan`.
- The user says "спроси Codex", "what does Codex think", "проверь второй моделью", "cross-validate", "second opinion", or pastes a review from a different agent and asks Claude to validate it.
- A long-running investigation where the same Codex thread needs context across many Claude Code turns.

### Routing — which command for which intent

| Intent | Command | Thread |
|---|---|---|
| Informational question ("how does X work", "is there already a Y") | `/ask` | `ask` (read-only) |
| Critique of code / diff / PR / a third-party review | `/review` (iterates to APPROVE; `--once` = single pass) | `review-<branch>` (default) or per-task |
| Stress-test a plan or design | `/plan` (iterates to APPROVE; `--once` = single pass) | `plan-<branch>` (default) or per-task |
| Reply back to something Codex said | `/reply [thread]` | named thread, default `review` |
| Structured disagreement on a decision, user watching | `/debate [--rounds]` | `debate-<slug>` |
| See plugin / thread / gate state in this repo | `/status` (read-only) | — |
| Dispose of a recorded finding (false-positive / accepted / deferred) | `/review-dispute` / `/review-accept` / `/review-defer <id>` | the finding's review thread |
| Anything else, isolated by topic | `/thread <name>` | `<name>` |
| Self-verification before finishing a turn | `/autoreview on` / `/autoplan on` | `review-<branch>` / `plan-<branch>` |

`ask`/`review`/`plan` carry intent framing (and `ask` defaults to read-only); `/thread` is a plain passthrough.

**`/review` and `/plan` iterate to APPROVE by default** — dispatch, address blocking findings, re-review, until APPROVE or the `--cap` round limit. Use `--once` for a single pass you act on yourself (and Judge-mode — a pasted third-party review — always runs a single classification pass, never a loop).

**One task = one thread.** `/review` and `/plan` default to a **branch-scoped** thread (`review-<branch>` / `plan-<branch>`, e.g. `review-main` on `main` — there is no main/master special-case) so each branch, and the matching `/autoreview` / `/autoplan` gate, stay on one isolated thread; the bare `review`/`plan` names are only via an explicit `--thread`. Reusing one thread across different tasks pays every later round's resume re-feeding the first task's history and muddies the audit log — start a fresh `--thread <topic>` instead.

**`--oneshot`** (any command except list/new): throwaway — no thread tracked, ephemeral Codex session, leaves no trace. Use for a one-off where no follow-up is planned. Without it, every command keeps a persistent thread.

## Threads

State files live in `.claude/codex-threads/` in the current repo (git-ignore this directory):

- `<name>.id` — saved Codex session UUID for the thread.
- `<name>.log` — append-only audit log of prompt/reply pairs (rotated to `.log.1` at ~1 MB; rotation happens before each append, so the latest entry is always in the current `.log`).
- `<name>.last-error.jsonl` — raw Codex stream from the most recent failure (the path the driver points you at on error).

List with `/thread-list`. Force-reset (drop saved UUID, next dispatch starts fresh) with `/thread-new <name>`.

The plugin never touches `~/.codex/sessions/rollout-*.jsonl` directly. Codex CLI manages those. `--oneshot` runs `codex exec --ephemeral` and writes **no** `.id`, `.log`, or rollout — a true throwaway.

## The driver — how every dispatch actually runs

All commands shell out to the bundled driver. When you need to dispatch without a command body in context (e.g. the autoreview gate pointed you here, or the user asked in prose), call it directly:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <thread> [--new|--oneshot|--require-existing] <<< "$PROMPT"
```

The prompt goes on stdin; the reply comes on stdout (show it verbatim). Exit codes: 4 = resume failed (ask before `--new`), 5 = tracked-file mutation under strict mode, 6 = `--require-existing` with no thread. The command files with the full per-intent steps live at `${CLAUDE_PLUGIN_ROOT}/commands/*.md`; lens templates at `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md`. The commands are `disable-model-invocation`, so you cannot invoke them as slash commands yourself — Read the command file and follow its steps instead.

## Codex is an agent, not an LLM endpoint

Codex CLI runs with `-C <repo>` and a sandbox. It reads files, runs `git diff`/`git log`, greps, and runs tests **on its own**. Do not stuff project context (CLAUDE.md, file contents, full diffs) into the prompt — Codex fetches what it needs. The only things it does NOT have are: the **intent** (what you were trying to do), the **scope** (what to look at), and your **specific focus**. Send those; let Codex gather the rest.

## Review and plan lenses

`/review` and `/plan` accept a `--lens` to focus the review and pick the report format. The lens templates live at `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md` — read that file, pick the block matching the `--lens` argument (or the default), and substitute it into the Codex prompt. They are canned prompts, not behavioural rules.

## Judge-mode framing — load-bearing rule

> **Status:** RED baseline reproduced 2026-05-31 (see `tests/scenarios/codex-triage/judge-mode-paste.json` — scenario paths here and below live in the plugin's source repo, not in the installed plugin). Verdict: **INCONSISTENT**. Both Sonnet and Haiku already construct side-by-side framing on their own. The actual failure that survives without this skill is narrower: Sonnet under neutral framing tacks on *"provide a corrected implementation that addresses the valid issues"* — turning Codex into a fix-applier instead of a judge. **That** is what this rule prevents.

When the user's input to `/review` (or `/thread`) contains **another agent's review or critique**, Codex's job is to **classify** the findings — not to apply fixes per them. The fix decision is the user's, after they see the classification.

### How to detect a third-party review

The input is a third-party review when it contains any of:

- Bullet lists of issues with severities ("critical / high / medium / low" or "valid / borderline / invalid").
- Phrases like "another agent found", "вот что нашёл агент", "review from", "findings:", "comments from <name>".
- A paste of structured findings — file:line references followed by a description and recommendation.
- A pasted PR review thread or GitLab MR thread.

### How to wrap the prompt

Send Codex the **code AND the review together** with classification (not application) instructions:

```
You are evaluating a third-party review.
Below is the CODE in scope, then a REVIEW of that code by a different agent.
For each finding in the review, classify as: valid (defensible by code+evidence)
/ borderline (style or judgement call) / invalid (refuted by code) / outdated
(was once true, code has changed). Cite the file:line you used to decide.
Do NOT accept claims at face value. End with a one-line overall verdict.

--- CODE ---
<the code in scope, or `git diff` output>

--- REVIEW ---
<the user's pasted review>
```

**Do NOT append "provide a corrected implementation" / "apply the valid fixes" / "rewrite the function with these fixes applied"** to the prompt. The user decides what to apply after seeing the classification. (Background: arXiv 2509.16533 found 23.5–80.3% sycophantic capitulation under sequential rebuttal framing. Agents already mitigate the framing problem unprompted; the residual failure is the helpfulness-driven "and fix it" addendum.)

When the input is the user's own direct question with no third-party review, pass it through unwrapped.

## Answering Codex back

> **Status:** RED baseline run 2026-06-01 (`tests/scenarios/codex-triage/reply-tool-request.json`) — **did NOT reproduce** on the happy path. With a working tool call, both Sonnet and Haiku ran the command and pasted real output unprompted, and neither re-affirmed Codex's self-retracted claim. Kept as a brief reminder, not a strong rule. A narrow failure may remain when the tool call itself **fails** (lazy path = guess the output instead of debugging) — untested.

When replying via `/reply`: do the tool work Codex asks for and paste the **verbatim** output (don't predict it); represent the user's position, not Codex's; reject a finding only with a concrete file:line; and don't re-affirm a claim Codex already walked back mid-message. Capable models do this anyway — it is spelled out for weak-model and tool-failure cases. Keep replies short (≤500 words).

## Debating Codex — anti-capitulation rules

> **Status:** RED run 2026-06-09 (`tests/scenarios/codex-triage/debate-capitulation.json`) — **INCONSISTENT, narrow but real**. Sonnet+neutral holds a correct position unaided; Haiku under "wrap it up" pressure concedes the opponent's false premise ("you're right that RFC allows retry") and slides into common-ground-seeking, while still holding the core behaviour. These rules target that premise-level capitulation onset (the first stage of the 23.5–80.3% collapse measured in arXiv 2509.16533).

When running `/debate`, you are a party with a position, not a moderator:

- **Commit first.** Form and state your own position (with evidence) BEFORE sending the topic to Codex and before reading its reply. Show it to the user.
- **Concede only on evidence.** You may change your stance on a point ONLY by naming the specific evidence (file:line, doc, measurement, counter-example) that changed your assessment. "That's a fair point" without named evidence is forbidden.
- **Advance or sharpen.** Each round must add new evidence or sharpen the disagreement. Repeating the prior round's argument means the debate is done — move to synthesis.
- **No unearned middle ground.** Do not split the difference to end the discussion. A compromise needs its own justification.
- **Argue, don't narrate the rules.** These rules govern your *reasoning*, not your *wording*. Never transcribe them into the message — no "уступаю с называнием доказательства", "на этом не уступаю", "вопрос на спор", "residual-решение, на котором не уступаю". Just make the argument: cite the evidence, add the new point, name the disagreement. Rule-compliance must show in the *substance*, not in labels announcing which rule you are obeying. Write in the conversation's language and avoid untranslated jargon ("wedge", "moat", "residual", "sequencing", "плацдарм") in your own turns; Codex's verbatim reply is exempt. (Observed leaking into a real debate — marqa `debate-product-functional-additions`, 2026-06-14: "Но из твоего же доказательства следует residual-решение, на котором не уступаю — SEQUENCING плацдарма".)
- **Honest synthesis.** The final round lists: points of agreement, residual disagreements (stated plainly, not papered over), what changed whose mind and why, and a recommendation that admits uncertainty where it exists.

## Validating inbound Codex findings — verify before you apply

> **Status:** RED run 2026-06-11 (`tests/scenarios/codex-triage/inbound-finding-validation.json`) — **did NOT reproduce** on strong models when the refuting evidence is in-context: both cells (neutral, and under APPROVE-gate + "тороплюсь" pressure) traced a wrong-in-context CRITICAL to the code, refused to merge the regression Codex's fix would introduce, and pushed back with file:line. Kept as a brief reminder for two reasons: (1) both agents justified verifying by citing `superpowers:receiving-code-review` **by name** — a skill most plugin users don't have installed, so the right behaviour was depending on a dependency the plugin doesn't ship; this section encodes the principle inline. (2) The test handed over the refuting code; the untested real failure is laziness about *going to read the files* when a finding looks plausible and the gate/user push for speed.

A Codex `/review` reply is a set of **claims to evaluate**, not orders to execute. Codex ran with `-C <repo>` but it saw the scope you sent and reasoned from the diff — it does **not** have the intent, the surrounding render/call path, or the reasons behind the current code. Treat every finding as "defensible until checked against the code."

Before applying ANY finding:

1. **Read the cited site and its consumers** — not just the line Codex quoted. The bug it describes often lives in how the value is *used* (a "stale field leaks" claim is false if the consumer gates on a different field).
2. **Check for a reason the current code is the way it is** — a comment, a named bug/issue, a test that pins the behaviour. Codex can't see why; you can.
3. **Check the suggested fix doesn't regress** — a "fix" that resets/widens/reorders can reintroduce exactly what the current code guards against.
4. **Classify:** valid (code+evidence back it) / borderline (style or judgement) / invalid (refuted by code) / outdated (was true, code moved on).
5. **Then act:** apply valid findings (and fix the neighborhood, below); reject invalid/outdated ones via `/reply` with the concrete file:line that refutes them; surface borderline ones — and anything that conflicts with a deliberate architectural decision — to the user rather than silently complying.

**If you can't verify** a finding without something you don't have (a runtime trace, a missing file, prod data), say so — "I can't confirm this without X; investigate, ask, or apply on your judgement?" — instead of applying on faith.

**The `/autoreview` APPROVE gate is not a reason to comply.** The gate releases on APPROVE *or* the round cap; an evidence-backed rejection is a legitimate way to resolve a round. Never apply a finding you believe is wrong just to make the gate release — that ships a regression to satisfy a counter. If Codex holds a finding you've refuted with file:line, escalate to the user (lower the gate, accept the cap), don't rubber-stamp it.

This is the inbound mirror of Judge-mode: there you tell Codex not to take a third party's claims at face value; here you don't take Codex's.

## Addressing findings — fix the neighborhood, not the cited line

> **Status:** RED run 2026-06-09 (`tests/scenarios/codex-triage/fix-neighborhood.json`) — **SPLIT**. On a small single-file fixture both models fix sibling sites unprompted (synthetic baseline unreproducible). The rule's regime is **cross-file / cross-call-chain neighborhoods at production scale**, where the failure is directly documented: a real 8-round review loop spent 3 rounds on ONE invariant because each fix patched exactly the cited site (first element → all elements → correct ordering).

When fixing a review finding, treat it as an instance of a **problem class**, not a line defect:

1. Before patching, ask: *what invariant does this finding describe?*
2. Search for every other site where that invariant applies — sibling functions, parallel code paths, other ingress points, the same check elsewhere in the call chain.
3. Fix ALL of them in this round, and say which sites you covered in the re-review request.
4. Check ordering/interaction: a guard added in the right place but after an earlier branch that bypasses it is not a fix.

A fix that addresses only the cited line invites the next round to flag the sibling — every such round costs a full Codex dispatch.

## Self-verification gates (`/autoreview`, `/autoplan`)

Arming reviews existing work first, then gates future turns. `/autoreview on`: if the branch is already dirty, run the review flow on it immediately (no manual step); then a Stop hook blocks the end of every future turn with unverified code changes until the per-branch review thread reaches an **APPROVE earned after arming** (the hook only parses verdicts from log content appended after an arming-time byte-offset snapshot — a stale APPROVE from a previous arming can never release, and `/thread-new`'s counter reset can neither fake nor mask a run) or the round cap. `/autoplan on`: stress-test already-changed plan docs immediately, then gate future plan-doc changes until the plan thread has seen one post-arming dispatch (normally your `/plan` stress-test — the gate detects thread-log growth, not command identity). The hook never calls Codex itself — when blocked, Read the command file its reason points you to (`<plugin>/commands/review.md` or `plan.md` — the commands are not model-invocable as slash commands) and follow its steps with the thread/lens from the reason, validate and address findings (fix the neighborhood), and finish the turn. Runaway-safe: the numeric-validated round cap is the hard terminator (malformed state fails open), the success release is the post-arming verdict (autoreview) / post-arming dispatch on the plan thread (autoplan), branch+dirty scoping keeps it out of unrelated turns. Armed state lives in `.claude/codex-threads/auto{review,plan}.armed`, branch-scoped. Arm on a clean tree — pre-existing dirt counts as unverified.

## Common failure modes

| Failure | Trigger | Counter |
|---|---|---|
| Silent fresh exec after resume failure | Driver exits 4 because `codex exec resume` failed (session expired / CLI upgrade / model unavailable) | Surface the exit-code-4 stderr to the user. Ask explicitly whether to `--new`. Never auto-rerun with `--new`. |
| Sandbox change mid-thread | User passes `CC_CODEX_FLAGS="-s read-only"` between turns of an existing thread | The sandbox is fixed at session creation and `codex exec resume` does not take `-s`; the change only applies on `--new` (which loses memory). (Newer CLIs do accept `-m`/`-c` on resume, but the driver omits them to keep the thread stable — `CC_CODEX_FLAGS` only affects the initial dispatch.) |
| Cross-thread contamination via `--last` | The saved `<name>.id` is missing or invalid | The driver falls back to a fresh exec, NOT to `codex exec resume --last`. `--last` would bind the named thread to whatever was most recently touched in `~/.codex/sessions/`. |
| Tracked-file mutation under `workspace-write` | Default Codex sandbox lets it write files; a "review" thread might edit code | Driver snapshots `git status --porcelain` pre/post each dispatch (filtering its own state dir) and warns on diff. Set `CC_CODEX_TRIAGE_STRICT=1` to make it fatal. For pure review, use `CC_CODEX_FLAGS="-s read-only"`. **Limitation:** porcelain detects status *transitions* only — if a file was already dirty and Codex changes it further, the status line is unchanged and the guard stays silent. Commit/stash WIP first for full protection. |
| Sycophantic capitulation on paste | A third-party review is pasted as "fix this" rather than "evaluate this" | Apply Judge-mode framing above. |
| Applying a wrong Codex finding to release the gate | `/autoreview` armed, Codex returns a plausible-but-wrong-in-context CRITICAL, user/gate push for speed | Validate against the code first (read the consumers, not just the cited line); reject with file:line via `/reply`; the gate's round cap, not compliance, is the escape hatch. |
| Guessing instead of running, when a tool call fails | `/reply` and the requested command errors (missing file, broken env) | Debug or report the failure honestly — do not guess the output. (Happy path: agents run it fine on their own.) |
| Wrong intent → wrong sandbox | Using `/review` for an informational question (or vice versa) | Route per the table above. `/ask` is read-only and informational; `/review` is adversarial. |
| Codex run stalled mid-investigation | A dispatch returned but produced no verdict / an incomplete reply (Codex was interrupted or ran long) | Do NOT restart the whole investigation. Resume the SAME thread asking it to report what it already concluded without re-running: `Your previous run stalled before a verdict. Do NOT restart — report the findings you already reached and give your verdict line.` The thread keeps its memory, so this recovers the work for one extra dispatch. |

## Prerequisites

- `codex` CLI on PATH (`npm install -g @openai/codex`).
- `~/.codex/config.toml` configured with a model the user is authorised for.

## Verification Gate

Before reporting the triage as done:

- [ ] The driver's stdout was shown to the user verbatim (do not paraphrase Codex's reply).
- [ ] If the driver warned about a porcelain diff, the diff was surfaced before continuing.
- [ ] If the driver exited with code 4 (resume failed), the user was asked whether to `--new` — not auto-resumed.
- [ ] If the input was a third-party review, the wrapped prompt to Codex was constructed using the Judge-mode template above, not as a rebuttal.
- [ ] If Codex returned review findings, each was validated against the code before applying — invalid/outdated ones rejected via `/reply` with file:line, not applied to release the gate.
- [ ] If replying via `/reply` and Codex requested tool work that failed, the failure was reported honestly — not papered over with a guessed result.
