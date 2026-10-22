---
name: codex-triage
user-invocable: false
description: Shared rules for every cc-codex-triage command - ownership, threads, model and effort, evidence handling, exit codes. Use when routing a request for a Codex second opinion, research or review to a command, or when a command points here. Each command's own description decides which command fits; this skill never starts paid work itself.
---

# Codex Triage

Route the user's request, or a bounded request from an already-authorized owning workflow,
to the matching command. Paid work starts only from an explicit user request or an
authorized owner.

| Intent | Command |
|---|---|
| Question answered from the repository or general knowledge | `/ask` |
| Current external evidence, documentation, or sourced comparison of approaches | `/research` |
| Existing code, diff, PR, or a pasted third-party review | `/review` |
| One plan or design to stress-test | `/plan` |
| Two or more defensible positions to contest | `/debate` |
| Answer to something Codex asked in an existing thread | `/reply` |
| Arbitrary named writable conversation (user-only: the model cannot invoke it) | `/thread` |
| Inspect or reset local state | `/status`, `/thread-list`, `/thread-new` |

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

An owner that authorizes calls names the task, the purpose and the call budget; that
authorization covers the bounded calls below without a question per invocation:

- `/ask`, `/research`, `/reply`: one dispatch per call.
- `/review`, `/plan`: iterate until `APPROVE` (for `/plan`, until only optional comments remain)
  or the `--cap` (default 5). `--once` forces a single pass; a `--oneshot` call leaves no thread
  to resume, so it is one pass too. `--background` changes where a call runs (see Long
  dispatches), never how many passes follow.
- `/debate`: its own `--rounds` ceiling.

The agent may inspect `/status` and `/thread-list`, and retire its own idle obsolete
threads with `/thread-new`. `/thread` is the user's.

## Terms

- **dispatch**: one paid Codex call. **round**: one completed dispatch on a thread.
- **attempt**: a claimed required-review round that counts against its cap.
- `--once`: the command makes a single pass instead of iterating. `--oneshot`: the driver
  runs an ephemeral Codex session with no thread state, for a question with no follow-up.
  They are independent and may be combined.

## Threads

Use one task per thread. Reuse a named thread only when its topic still matches;
otherwise choose a distinct name. Default names use the branch or standalone directory.

Threads are scoped to the current Git worktree or, outside Git, the physical working
directory. The driver passes that context on resume. Research and debate can be general;
only required review needs Git. Retain a worktree through its review and delivery.

**Model and effort.** A thread records the model and effort from the first dispatch that
names them. Later dispatches without the flags reuse the recorded values; a different
explicit value replaces them for that dispatch and every later one on the thread, and the
driver prints the change. Until something is recorded, Codex's own configuration applies.
`--oneshot` records nothing. Commands forward `--model` / `--effort` only when supplied.
Dollar cost is unknown unless usage evidence shows it; report an unknown price as unknown.

**Sandbox.** A thread keeps the sandbox it was created with, in its profile: `--read-only`
at creation (`/ask`, `/research`, `/debate`) makes every later call on it read-only, including
`/reply`; a thread created without it (`/review`, `/plan`, `/thread`) keeps running in Codex's
configured sandbox. A call that passes `--read-only` applies it to that call only. A saved
thread with no recorded sandbox (created by an older version) resumes read-only; retire it with
`/thread-new` to choose again.

**Required-review threads.** Any dispatch to a thread that holds required-review state
revokes its recorded approval. Each advisory command therefore runs
`review-state.sh advisory-check "$THREAD" || exit $?` before dispatching, except for
`--oneshot` (no thread state) and the two commands that handle the case themselves: `/reply`
follows [required-review.md](references/required-review.md) for such a thread, and `/thread`
is the user's, who accepts the revocation. On `REQUIRED_THREAD_RESERVED` (exit 10) the caller
targets a different `--thread`.

**Recovery.** If resume exits 4, read the diagnostic and recover within existing
authorization. When recovery needs a fresh session, retire an owned advisory thread with
`/thread-new` (the archive is retained). For required review, reconcile the pending claim
first, using the Recovery section of required-review.md. A busy thread (exit 10) is waited
for. Another active task's thread and unresolved findings stay as they are. Report routine
cleanup briefly; ask only when ownership or an outstanding user decision is unclear.

## Exit codes

On a non-zero exit, act per this table; the maintainer-level list is the header of
`scripts/codex-thread.sh`.

| Code | Meaning | Action |
|---|---|---|
| 1 | Usage error | Fix the arguments |
| 2 | Codex CLI or Python 3.8+ unavailable | Report it; nothing was dispatched |
| 3 | `codex exec` failed (new thread or `--oneshot`) | Read the printed diagnostic before retrying |
| 4 | Resume failed; saved session kept | Recover as above |
| 5 | Tracked files changed under `--strict` (required review only) | Show the diff; inspect before continuing |
| 6 | `--require-existing` found no thread | Start one with `/ask`, `/review` or `/plan` |
| 7 | Invalid context directory or unsafe thread state | Inspect the path the diagnostic names |
| 9 | Detach handshake timed out on a live child | Read `<thread>.detach-output` and `.detach-stderr` |
| 10 | Thread busy, or a `review-state.sh` refusal named on stderr | Wait, use another `--thread`, or follow the named marker |
| 11 | `STALE`: candidate changed or dispatch incomplete | See required-review.md |
| 14 | Prompt header differs from the claim; nothing was dispatched | Rebuild it with `review-state.sh header` |
| 20 | Long dispatch still running; the worker is unaffected | Run the printed `dispatch.sh --watch` command as a background task; do not dispatch the turn again |
| 21 | Watched dispatch left no status record; outcome unconfirmed | Treat as failure; read `/status` and the thread log before retrying |

**Long dispatches.** `/review`, `/plan`, `/research`, `/debate` and `/reply` call `dispatch.sh`,
which already detaches long runs past the 600-second tool ceiling; `/ask` and `/thread` are short
foreground calls. `--background` means running that `dispatch.sh` call as a Claude-managed
background task, with no second detach layer around it.

## Prompt boundary

Codex can use its available tools and local context, including relevant files, diffs
and tests when a repository is part of the task. Send only what it cannot infer:

- the user's intent;
- the review or question scope;
- the requested focus;
- external evidence not present in the repository.

For research, return cited conclusions and uncertainty. For review, show findings
and the exact final verdict; after fixes, summarize the delta and link
the full thread log. Show the full answer when requested. Report tool failures instead
of predicting output. Never rewrite REQUEST_CHANGES into APPROVE.

## Reviews

Read [review-lenses.md](references/review-lenses.md) only for `/review` or
`/plan`. Use the default lens unless the user requests another focus. Read
[required-review.md](references/required-review.md) for `--required`, for `/reply` on a
thread that has required-review state, and for the cap and recovery rules.

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

For a pasted third-party review, ask Codex to classify the findings in one pass
and leave implementation out of the prompt.

## Debate

State your position before sending the first prompt. Change it only when named
evidence changes the assessment. Each round must add evidence or sharpen the
remaining disagreement; otherwise synthesize and stop. Synthesis reports the
disagreement that remains.

## Done

- The selected command matches the user's intent.
- The answer or failure is shown without fabrication.
- Review findings are verified before any fix.
- Required approval is claimed only through `/review --required` and its exact
  machine marker, never inferred from prose or `/status`.
