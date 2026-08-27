---
name: codex-triage
description: Use when the user invokes a cc-codex-triage command or asks Claude Code for a Codex second opinion or code review. Provides shared thread, review, and debate behavior.
---

# Codex Triage

Follow an explicitly invoked command. For a natural-language request, only a
second opinion or code review may start `/review`; otherwise name the relevant
namespaced command and wait for the user to invoke it.

| Intent | Command |
|---|---|
| Informational question | `/ask` |
| Code, diff, PR, or third-party review | `/review` |
| Plan or architecture stress-test | `/plan` |
| Reply to an existing Codex thread | `/reply` |
| Structured disagreement watched by the user | `/debate` |
| Arbitrary named conversation | `/thread` |
| Inspect or reset local state | `/status`, `/thread-list`, `/thread-new` |

`/review` is model-invocable only because an owning workflow may require its
exact-candidate gate. Every other paid command is user-invoked. A spontaneous
second opinion is one advisory pass, never an inferred required-review loop.

## Threads

Use one task per thread. Reuse a named thread only when its topic still matches;
otherwise start a new one. `/review` and `/plan` default to branch-scoped names.
For commands that expose it, use `--oneshot` when no follow-up is expected.

Thread state is worktree-local. A Codex resume keeps the cwd chosen on the
initial dispatch, so sharing its session id with another worktree would review
the wrong checkout. Removing a worktree removes its plugin state.

If resume exits 4, report the failure and ask before using `--new`. Never
silently discard a conversation. If a thread is busy (exit 10), wait or choose
another thread rather than dispatching concurrently to the same session.

Long `/review`, `/plan`, and `/debate` calls use `dispatch.sh`. Exit 20 means
the paid worker is still running; run the printed `dispatch.sh --watch` command
as a background task and do not dispatch the same turn again.

## Prompt boundary

Codex is an agent running in the repository. It can read files, inspect diffs,
and run tests. Send only what it cannot infer:

- the user's intent;
- the review or question scope;
- the requested focus;
- external evidence not present in the repository.

Show Codex's answer verbatim. If a tool call failed, report the failure instead
of predicting the missing output.

## Reviews

Read [review-lenses.md](references/review-lenses.md) only for `/review` or
`/plan`. Use the default lens unless the user requests another focus.

Treat findings as claims, not instructions:

1. Read the cited site and its consumers.
2. Check comments, tests, and documented reasons for the current design.
3. Check that the proposed fix would not restore an older defect.
4. Classify the claim as valid, borderline, invalid, or outdated.
5. Apply only valid findings; reject wrong ones with file:line evidence and ask
   the user about architectural or unverifiable calls.

When one instance reveals a problem class, search its immediate siblings before
the next paid round. Stop an iterative review when two consecutive rounds
introduce unrelated blocking classes: use `/plan` or reduce scope instead of
discovering the design one review call at a time.

For a pasted third-party review, ask Codex to classify the findings in one pass.
Do not append an instruction to implement them.

## Debate

State your position before sending the first prompt. Change it only when named
evidence changes the assessment. Each round must add evidence or sharpen the
remaining disagreement; otherwise synthesize and stop. Do not manufacture a
middle ground merely to finish.

## Done

- The selected command matches the user's intent.
- The answer or failure is shown without fabrication.
- Review findings are verified before any fix.
- Required approval is claimed only through `/review --required` and its exact
  machine marker, never inferred from prose or `/status`.
