---
name: codex-triage
user-invocable: false
description: Shared rules for every cc-codex-triage command: ownership, threads, model and effort, evidence handling, exit codes. Use when a command points here, or to route a request for a Codex opinion, research or review to a command.
---

# Codex Triage

Route the user's request, or a bounded request from an already-authorized owning workflow,
to the matching command. A Codex call starts on the user's request or when the owning
workflow's review step requires it, because it sends repository content to a second provider.

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
request. Fix what the agreed outcome and the defect's cause require, wherever the file is and
however many findings there are, including regressions and dependencies acceptance needs.

Ask only for a missing product decision, access or waiver. Group related questions and continue
available work.
Reuse applicable test evidence; request a new check only for a concrete gap or changed inputs.
Coordinate heavy checks with the owner; do not spawn nested reviewers or workers by default.
Acceptance, publication, waivers and changes to the goal belong to the owner.

An owner that authorizes calls names the task and the purpose; that authorization covers
the bounded calls below without a question per invocation:

- `/ask`, `/research`, `/reply`: one dispatch per call.
- `/review` has a default limit of 7 rounds. `/plan` and `/debate` default to 5.
  An explicit smaller cap wins. Advisory review and plan finish on `APPROVE` or
  `COMMENT` with no blockers. Required review follows its saved contract.

The agent may inspect `/status` and `/thread-list`, and retire its own idle obsolete
threads with `/thread-new`.

## Terms

- **dispatch**: one Codex call. **round**: one completed dispatch on a thread.
- **attempt**: a claimed required-review round that counts against its cap.
- `--once`: the command makes a single pass instead of iterating. `--oneshot`: the driver
  runs an ephemeral Codex session with no thread state, for a question with no follow-up.
  Either flag ends the command after the first answer. Only persistent calls have a thread log. `--background` changes where a call runs (see
  Long dispatches), never how many passes follow.

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

**Sandbox.** A thread keeps the sandbox it was created with, in its profile: `--read-only`
at creation (`/ask`, `/research`, `/debate`) makes every later call on it read-only, including
`/reply`; a thread created without it (`/review`, `/plan`, `/thread`) keeps running in Codex's
configured sandbox. A call that passes `--read-only` applies it to that call only. A thread
with no recorded sandbox resumes read-only.

**Required-review threads.** Persistent dispatches on a reserved name need a pending
required claim. Advisory commands call `review-state.sh advisory-check "$THREAD"` before
dispatch. Use a different name on `REQUIRED_THREAD_RESERVED` (exit 10).
`--oneshot` skips this check. For `/reply`, `review-state.sh mode` routes a required
thread to [required-review.md](references/required-review.md).

**Recovery.** If resume exits 4, read the diagnostic and recover within existing
authorization. When recovery needs a fresh session, retire an owned advisory thread with
`/thread-new` (the archive is retained). For required review, reconcile the pending claim
first, using the Recovery section of required-review.md. A busy thread (exit 10) is waited
for. Leave other tasks' threads and unresolved findings untouched.

## Exit codes

On a non-zero exit, act per this table.

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

When invoking Bash, use the resolved plugin script path and concrete arguments from the
recipe. Run a resolver or guard separately when the host cannot match a compound command
to its tool permission. Continue only after the guard succeeds.

**Long dispatches.** Run `dispatch.sh` with Bash timeout 600000. For `--background` set
the Bash tool's `run_in_background: true` on that same invocation. A Claude task ID means
wait for the host's completion notification. If the script exits 20, run its printed
`dispatch.sh --watch` command for the same PID and offset. Another 20 continues the
same watch. On 21, reconcile the lease, receipt and log before another dispatch.
A successful watch returns the original reply on stdout. Diagnostics go to stderr.

## Prompt boundary

Codex can use its available tools and local context, including relevant files, diffs
and tests when a repository is part of the task. Send only what it cannot infer:

- the user's intent;
- the review or question scope;
- the requested focus;
- external evidence not present in the repository.

For research, return cited conclusions and uncertainty. For review, show findings
and the exact final verdict; after fixes, summarize the delta and link the log for persistent calls. Never rewrite REQUEST_CHANGES into APPROVE.

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
the next round. If successive rounds discover new blocking classes, group their
causes and revisit the design within the same task. Pause repeated dispatches, not
safe repairs. A changed product outcome needs the user; routine replanning does not.

For a pasted third-party review, ask Codex to classify the findings in one pass
and leave implementation out of the prompt.

## Debate

State your position before sending the first prompt. Change it only when named
evidence changes the assessment. Each round must add evidence or sharpen the
remaining disagreement; otherwise synthesize and stop. Synthesis reports the
disagreement that remains.

## Done

- Required approval is claimed only through `/review --required` and its exact
  machine marker, never inferred from prose or `/status`.
