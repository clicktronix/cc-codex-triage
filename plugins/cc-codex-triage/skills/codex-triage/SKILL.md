---
name: codex-triage
description: Use when the user wants to send code, a plan, or another agent's review to OpenAI Codex CLI for a second opinion, especially when the conversation will continue across multiple turns or when validating findings from a different agent.
---

# Codex Triage

## When to invoke

- The user types `/codex-review`, `/codex-plan`, `/codex-thread <name>`, `/codex-thread-list`, `/codex-thread-new` (the plugin's commands).
- The user says "спроси Codex", "what does Codex think", "проверь второй моделью", "cross-validate", "second opinion", or pastes a review from a different agent and asks Claude to validate it.
- A long-running investigation where the same Codex thread needs context across many Claude Code turns (typically iterating on a plan, an architecture, or a finding).

Do not invoke for one-shot Codex use where no follow-up is planned — running `codex exec` directly via Bash is fine.

## Threads

Default named threads:

- `review` — used by `/codex-review`. For code, diffs, PRs, finding triage.
- `plan` — used by `/codex-plan`. For architecture, design docs, plans.

Custom names via `/codex-thread <name>`. List with `/codex-thread-list`. Force-reset (drop saved UUID, next dispatch starts fresh) with `/codex-thread-new <name>`.

State files live in `.claude/codex-threads/` in the current repo:

- `<name>.id` — saved Codex session UUID for the thread.
- `<name>.log` — append-only audit log of prompt/reply pairs (rotated at ~1 MB).

The plugin never touches `~/.codex/sessions/rollout-*.jsonl` directly. Codex CLI manages those.

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

## Common failure modes

| Failure | Trigger | Counter |
|---|---|---|
| Silent fresh exec after resume failure | Driver exits 4 because `codex exec resume` failed (session expired / CLI upgrade / model unavailable) | Surface the exit-code-4 stderr to the user. Ask explicitly whether to `--new`. Never auto-rerun with `--new`. |
| Sandbox or model change mid-thread | User passes `CC_CODEX_FLAGS="-s read-only"` between turns of an existing thread | `codex exec resume` rejects `-s`, `-m`, approval `-c`. Tell the user the change only takes effect on `--new` (and that loses memory). |
| Cross-thread contamination via `--last` | The saved `<name>.id` is missing or invalid | The driver falls back to a fresh exec, NOT to `codex exec resume --last`. `--last` would bind the named thread to whatever was most recently touched in `~/.codex/sessions/`. |
| Tracked-file mutation under `workspace-write` | Default Codex sandbox lets it write files; a "review" thread might edit code | Driver snapshots `git status --porcelain` pre/post each dispatch and warns on diff. Set `CC_CODEX_TRIAGE_STRICT=1` to make it fatal. For pure review, use `CC_CODEX_FLAGS="-s read-only"`. |
| Sycophantic capitulation on paste | A third-party review is pasted as "fix this" rather than "evaluate this" | Apply Judge-mode framing above. |

## Prerequisites

- `codex` CLI on PATH (`npm install -g @openai/codex`).
- `~/.codex/config.toml` configured with a model the user is authorised for.

## Verification Gate

Before reporting the triage as done:

- [ ] The driver's stdout was shown to the user verbatim (do not paraphrase Codex's reply).
- [ ] If the driver warned about a porcelain diff, the diff was surfaced before continuing.
- [ ] If the driver exited with code 4 (resume failed), the user was asked whether to `--new` — not auto-resumed.
- [ ] If the input was a third-party review, the wrapped prompt to Codex was constructed using the Judge-mode template above, not as a rebuttal.
