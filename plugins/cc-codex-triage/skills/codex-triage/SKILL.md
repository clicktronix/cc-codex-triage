---
name: codex-triage
description: Use when you want a persistent cross-agent conversation with OpenAI Codex CLI — same Codex thread across multiple Claude Code turns, with Judge-mode framing to suppress sycophantic capitulation when triaging another agent's review.
---

# Codex Triage

## Overview

Codex CLI persists every `codex exec` session as a rollout file in `~/.codex/sessions/`. `codex exec resume <UUID>` continues the exact same conversation with full memory. This skill exposes that as **named threads** so Claude Code can hold open-ended triage dialogues with Codex without losing context between turns.

**Not a fix loop.** Unlike `dementev-dev/adversarial-review` (5-round approve/revise) or `hamelsmu/claude-review-loop` (one-shot multi-agent fan-out), this skill is for **open-ended dialogue** — paste, ask follow-ups, dig in, no round cap, no enforced verdict.

## When to invoke

- User wants Codex's opinion on something and is likely to iterate: `/codex-review <paste>`, `/codex-plan <paste>`.
- User pastes a review or finding from another agent and asks Claude to validate it: invoke `/codex-review` in **Judge mode** (see below).
- User says "спроси Codex", "что скажет Codex", "проверь второй моделью", "cross-validate".
- Long-running technical investigation where Codex needs to retain prior context across many Claude turns.

**Do NOT use** for one-shot reviews where no follow-up is expected — `/codex-review` would still work but creates an orphaned thread file. Use the unnamed `codex exec` directly via Bash for true one-shots.

## Threads

The default named threads are:

- `review` — used by `/codex-review`. For code, diffs, PRs, finding triage.
- `plan` — used by `/codex-plan`. For architecture, design docs, plans.

Custom named threads via `/codex-thread <name>`. List with `/codex-thread-list`. Force-reset (start fresh, drop memory) with `/codex-thread-new <name>`.

Thread UUIDs persist under `.claude/codex-threads/<name>.id` in the current repo. Append-only audit log at `.claude/codex-threads/<name>.log`.

## Judge mode — anti-sycophancy framing

When forwarding **another agent's review or critique** into Codex, do NOT phrase it as:

> ❌ "Here is criticism of my code from another agent: [paste]. Please verify and fix."

This is sequential rebuttal framing. arXiv 2509.16533 (EMNLP 2025 Findings) measured **23.5%-80.3% sycophantic capitulation** under this mode — Codex will tend to agree with the paste even if it's wrong.

Instead, frame **side-by-side** as a third-party judge:

> ✅ "Here is code: [paste]. Here is a review of that code by a different agent: [paste]. Evaluate the review as a third party — for each finding, decide: valid (defensible by code+evidence), borderline (style or judgement call), invalid (refuted by code), or outdated (was once true, code has changed). Do not accept claims at face value."

The same paper shows Judge mode (side-by-side) reduces capitulation by 1.5-2× vs sequential rebuttal.

`/codex-review` SHOULD apply this framing automatically when its argument is or contains another agent's review.

## What to expect from Codex

The driver reads Codex's stdout via `codex exec ... -o /tmp/...` (the `--output-last-message` file). This is the assistant's final message only, not the full JSONL event stream. For deep debugging of a Codex run, inspect `.claude/codex-threads/<name>.log` for the prompt/reply pair, or the underlying `~/.codex/sessions/rollout-*.jsonl`.

Codex defaults to whatever model+sandbox the user has configured in `~/.codex/config.toml`. Override with `CC_CODEX_FLAGS` env var (e.g. `CC_CODEX_FLAGS="-m gpt-5.5 -s read-only"`).

## Common Failure Modes

- **Silent fresh exec on resume failure.** If `codex exec resume <UUID>` fails (session expired, model unavailable, CLI upgrade broke wire format), do NOT automatically start a fresh exec. The user's memory of "Codex remembers what we discussed" would silently break. The driver returns exit 4 with a clear warning — surface it to the user and ask whether to `--new`.
- **Sandbox/model mid-thread.** `codex exec resume` does NOT accept `-s`, `-m`, or approval `-c` overrides. These are properties of the original session. To change sandbox, you must `--new` (loses memory).
- **Cross-thread contamination via `--last`.** The driver never uses `--last` — it would pick whatever session was most recently touched in `~/.codex/sessions/`, which might be from a different thread or a different repo entirely. Threads are pinned to their saved UUID or nothing.
- **Tracked-file mutation under `workspace-write`.** Codex with the default sandbox can edit files. The driver snapshots `git status --porcelain` pre/post and warns on diff (set `CC_CODEX_TRIAGE_STRICT=1` to make this fatal). For pure review/triage where Codex must not touch files, run with `CC_CODEX_FLAGS="-s read-only"`.
- **Sycophantic capitulation on paste.** See Judge mode above. If you paste another agent's claims as a direct rebuttal, expect Codex to capitulate. Always frame side-by-side.

## Prerequisites

- `codex` CLI on PATH (`npm install -g @openai/codex`).
- `~/.codex/config.toml` configured with a model the user is authorised for.

## Verification Gate

Before claiming the triage is done:

1. The user has actually read Codex's reply (not just acknowledged that it ran).
2. For findings that survived Judge-mode evaluation, they have a concrete next action — applied, deferred with reason, or rejected with reason.
3. If a resume failed, the user has explicitly chosen to `--new` (not assumed it).
