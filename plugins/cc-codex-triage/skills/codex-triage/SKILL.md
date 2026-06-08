---
name: codex-triage
description: Use when the user wants to involve OpenAI Codex CLI from Claude Code — asking it a question, getting a second opinion on code or a plan, validating another agent's findings, or replying to something Codex said — especially across multiple turns of the same conversation.
---

# Codex Triage

## When to invoke

- The user types any plugin command: `/codex-ask`, `/codex-review`, `/codex-plan`, `/codex-reply`, `/codex-thread <name>`, `/codex-thread-list`, `/codex-thread-new`.
- The user says "спроси Codex", "what does Codex think", "проверь второй моделью", "cross-validate", "second opinion", or pastes a review from a different agent and asks Claude to validate it.
- A long-running investigation where the same Codex thread needs context across many Claude Code turns.

### Routing — which command for which intent

| Intent | Command | Thread |
|---|---|---|
| Informational question ("how does X work", "is there already a Y") | `/codex-ask` | `ask` (read-only) |
| Critique of code / diff / PR / a third-party review | `/codex-review [--lens]` | `review` |
| Stress-test a plan or design | `/codex-plan [--lens]` | `plan` |
| Reply back to something Codex said | `/codex-reply` | the active thread |
| Anything else, isolated by topic | `/codex-thread <name>` | `<name>` |

`ask`/`review`/`plan` carry intent framing (and `ask` defaults to read-only); `/codex-thread` is a plain passthrough.

**`--oneshot`** (any command except list/new): throwaway — no thread tracked, ephemeral Codex session, leaves no trace. Use for a one-off where no follow-up is planned. Without it, every command keeps a persistent thread.

## Threads

State files live in `.claude/codex-threads/` in the current repo (git-ignore this directory):

- `<name>.id` — saved Codex session UUID for the thread.
- `<name>.log` — append-only audit log of prompt/reply pairs (rotated to `.log.1` at ~1 MB; rotation happens before each append, so the latest entry is always in the current `.log`).
- `<name>.last-error.jsonl` — raw Codex stream from the most recent failure (the path the driver points you at on error).

List with `/codex-thread-list`. Force-reset (drop saved UUID, next dispatch starts fresh) with `/codex-thread-new <name>`.

The plugin never touches `~/.codex/sessions/rollout-*.jsonl` directly. Codex CLI manages those. `--oneshot` runs `codex exec --ephemeral` and writes **no** `.id`, `.log`, or rollout — a true throwaway.

## Codex is an agent, not an LLM endpoint

Codex CLI runs with `-C <repo>` and a sandbox. It reads files, runs `git diff`/`git log`, greps, and runs tests **on its own**. Do not stuff project context (CLAUDE.md, file contents, full diffs) into the prompt — Codex fetches what it needs. The only things it does NOT have are: the **intent** (what you were trying to do), the **scope** (what to look at), and your **specific focus**. Send those; let Codex gather the rest.

## Review and plan lenses

`/codex-review` and `/codex-plan` accept a `--lens` to focus the review and pick the report format. The lens templates live in `references/review-lenses.md` — read that file, pick the block matching the `--lens` argument (or the default), and substitute it into the Codex prompt. They are canned prompts, not behavioural rules.

## Judge-mode framing — load-bearing rule

> **Status:** RED baseline reproduced 2026-05-31 (see `tests/scenarios/codex-triage/judge-mode-paste.json`). Verdict: **INCONSISTENT**. Both Sonnet and Haiku already construct side-by-side framing on their own. The actual failure that survives without this skill is narrower: Sonnet under neutral framing tacks on *"provide a corrected implementation that addresses the valid issues"* — turning Codex into a fix-applier instead of a judge. **That** is what this rule prevents.

When the user's input to `/codex-review` (or `/codex-thread`) contains **another agent's review or critique**, Codex's job is to **classify** the findings — not to apply fixes per them. The fix decision is the user's, after they see the classification.

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

When replying via `/codex-reply`: do the tool work Codex asks for and paste the **verbatim** output (don't predict it); represent the user's position, not Codex's; reject a finding only with a concrete file:line; and don't re-affirm a claim Codex already walked back mid-message. Capable models do this anyway — it is spelled out for weak-model and tool-failure cases. Keep replies short (≤500 words).

## Common failure modes

| Failure | Trigger | Counter |
|---|---|---|
| Silent fresh exec after resume failure | Driver exits 4 because `codex exec resume` failed (session expired / CLI upgrade / model unavailable) | Surface the exit-code-4 stderr to the user. Ask explicitly whether to `--new`. Never auto-rerun with `--new`. |
| Sandbox change mid-thread | User passes `CC_CODEX_FLAGS="-s read-only"` between turns of an existing thread | The sandbox is fixed at session creation and `codex exec resume` does not take `-s`; the change only applies on `--new` (which loses memory). (Newer CLIs do accept `-m`/`-c` on resume, but the driver omits them to keep the thread stable — `CC_CODEX_FLAGS` only affects the initial dispatch.) |
| Cross-thread contamination via `--last` | The saved `<name>.id` is missing or invalid | The driver falls back to a fresh exec, NOT to `codex exec resume --last`. `--last` would bind the named thread to whatever was most recently touched in `~/.codex/sessions/`. |
| Tracked-file mutation under `workspace-write` | Default Codex sandbox lets it write files; a "review" thread might edit code | Driver snapshots `git status --porcelain` pre/post each dispatch (filtering its own state dir) and warns on diff. Set `CC_CODEX_TRIAGE_STRICT=1` to make it fatal. For pure review, use `CC_CODEX_FLAGS="-s read-only"`. **Limitation:** porcelain detects status *transitions* only — if a file was already dirty and Codex changes it further, the status line is unchanged and the guard stays silent. Commit/stash WIP first for full protection. |
| Sycophantic capitulation on paste | A third-party review is pasted as "fix this" rather than "evaluate this" | Apply Judge-mode framing above. |
| Guessing instead of running, when a tool call fails | `/codex-reply` and the requested command errors (missing file, broken env) | Debug or report the failure honestly — do not guess the output. (Happy path: agents run it fine on their own.) |
| Wrong intent → wrong sandbox | Using `/codex-review` for an informational question (or vice versa) | Route per the table above. `/codex-ask` is read-only and informational; `/codex-review` is adversarial. |

## Prerequisites

- `codex` CLI on PATH (`npm install -g @openai/codex`).
- `~/.codex/config.toml` configured with a model the user is authorised for.

## Verification Gate

Before reporting the triage as done:

- [ ] The driver's stdout was shown to the user verbatim (do not paraphrase Codex's reply).
- [ ] If the driver warned about a porcelain diff, the diff was surfaced before continuing.
- [ ] If the driver exited with code 4 (resume failed), the user was asked whether to `--new` — not auto-resumed.
- [ ] If the input was a third-party review, the wrapped prompt to Codex was constructed using the Judge-mode template above, not as a rebuttal.
- [ ] If replying via `/codex-reply` and Codex requested tool work that failed, the failure was reported honestly — not papered over with a guessed result.
