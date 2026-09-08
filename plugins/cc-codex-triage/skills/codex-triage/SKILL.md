---
name: codex-triage
user-invocable: false
description: Use when the user invokes a cc-codex-triage command or asks Claude Code for a Codex second opinion or code review. Provides shared thread, review, and debate behavior.
---

# Codex Triage

Route the user's request, or a bounded request from an already-authorized owning workflow,
to the matching command. Do not start paid work spontaneously.

| Intent | Command |
|---|---|
| Informational question | `/ask` |
| Code, diff, PR, or third-party review | `/review` |
| Plan or architecture stress-test | `/plan` |
| Reply to an existing Codex thread | `/reply` |
| Structured disagreement watched by the user | `/debate` |
| Arbitrary named conversation | `/thread` |
| Inspect or reset local state | `/status`, `/thread-list`, `/thread-new` |

`/ask`, `/plan`, `/review`, and `/reply` support authorized workflow calls. The owner names
the task, purpose and permitted review budget; use one advisory pass unless iteration was
requested. `/debate`, arbitrary `/thread`, and reset remain user-invoked.

## Ownership

The invoking workflow owns implementation, native tasks, verification and delivery. Return
validated findings to it; do not create issues/tasks per finding, waive acceptance, or run a
second lifecycle. Standalone advisory commands may fix confirmed defects within the user's
request. Scope follows the agreed outcome and defect causality, not file location, severity
or finding count. Include regressions and dependencies needed to meet acceptance.

Ask only for a missing product decision, access or waiver. Group related questions and continue
available work. Routine architecture fixes and gathering missing evidence need no new permission.
Reuse applicable test evidence; request a new check only for a concrete gap or changed inputs.
Coordinate heavy checks with the owner; do not spawn nested reviewers or workers by default.

## Threads

Use one task per thread. Reuse a named thread only when its topic still matches;
otherwise start a new one. `/review` and `/plan` default to branch-scoped names.
For commands that expose it, use `--oneshot` when no follow-up is expected.

Thread state is worktree-local by policy. The driver passes this checkout on every
dispatch, including resume. Retain it through required review and delivery; archive
needed logs before removing a disposable worktree.

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

Show findings and the exact final verdict; after fixes, summarize the delta and link
the full thread log. Show the full answer when requested. Report tool failures instead
of predicting output. Never rewrite REQUEST_CHANGES into APPROVE.

## Reviews

Read [review-lenses.md](references/review-lenses.md) only for `/review` or
`/plan`. Use the default lens unless the user requests another focus.

Treat findings as claims, not instructions:

1. Read the cited site and its consumers.
2. Check comments, tests, and documented reasons for the current design.
3. Check that the proposed fix would not restore an older defect.
4. Classify the claim as valid, borderline, invalid, or outdated.
5. Validate scope against spec/rules, apply confirmed fixes when you own implementation,
   and refute wrong claims with evidence. Return findings when a workflow owns the task.

When one instance reveals a problem class, search its immediate siblings before
the next paid round. If successive rounds discover new blocking classes, group their
causes and revisit the design within the same task. Pause repeated paid dispatches, not
safe repairs. A changed product outcome needs the user; routine replanning does not.
A required-review cap stops paid attempts and delivery. Report the missing approval
once to the owner, continue safe work, and never reset merely to seek an easier verdict.

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
