# cc-codex-triage plugin

Persistent, worktree-local Codex CLI conversations for Claude Code.

## Commands

- `/ask`: informational question, read-only by default.
- `/research`: one research pass using primary sources, live web search and repository evidence.
- `/review`: advisory code review; `--once` for one pass.
- `/review --required --base <ref> --spec <path>`: machine-checked approval
  for one exact clean candidate.
- `/plan`: plan or architecture stress-test.
- `/reply`: reply to an existing Codex thread.
- `/debate`: visible, bounded design disagreement.
- `/thread`: arbitrary named conversation.
- `/thread-list`, `/thread-new`, `/status`: inspect or reset local state.

Commands are namespaced: `/cc-codex-triage:review`,
`/cc-codex-triage:ask`, and so on. `/review` and `/plan` collide with Claude
Code built-ins, so use their namespaced forms.

One internal routing skill, `codex-triage`, supplies ownership, evidence and thread
conventions. It is loaded when relevant; use the commands above for actions.
`ask`, `research`, `plan`, `review` and `reply` may be called by an already-authorized workflow.
The owner retains tasks, fixes and delivery; the bridge does not create backlog items.

## Required review

Required review captures a clean candidate's canonical base, tracked spec,
HEAD, and tree before dispatch. It accepts only one bare final `APPROVE` from
the claimed round with a completed driver receipt. The driver checks actual clean
HEAD/tree before and after the call. Wrong prompt scope, missing receipts or decisions,
cap exhaustion and detected candidate movement refuse approval. A later reply or failed
dispatch revokes the previous approval. Endpoint checks do not prove the filesystem
was immutable throughout the call; the owner must keep the review candidate stable.

The only delivery marker is:

```text
CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<sha> tree=<sha> base_sha=<sha> spec_path=<path>
```

An owning workflow must run `scripts/review-state.sh check <thread>` and compare
the marker's `head` with its candidate. `/status` is informational.

## State

`scripts/state-dir.sh` stores state under the current worktree's absolute Git
directory:

```text
<absolute-git-dir>/cc-codex-triage/threads/
```

Session ids are worktree-local by policy; the driver passes this checkout on resume
too. Keep it until delivery and archive needed history before removing it. Upgrading
0.11 to 0.12 preserves sessions, but old approvals need a fresh claimed round to acquire
a dispatch receipt. Earlier `.claude/codex-threads` and common-Git state are not migrated;
preserve any useful legacy logs before choosing a new thread.

Same-thread dispatches are serialized. A busy thread exits 10. Resume failure
exits 4 and preserves the saved id until the user explicitly chooses
`/thread-new`. Explicit resets preserve prior plugin state in a tar file at `<thread>.archive.*`.
Reviewers run in separate process groups; cancellation signals the entire reviewer process group
without signalling the host terminal. Watcher timeout still hands off a live worker.

## Permissions

Command frontmatter scopes pre-approved Bash to this plugin's executable
scripts through `${CLAUDE_PLUGIN_ROOT}`. It does not grant arbitrary Bash for
the turn. These grants do not remove other host tools. `/debate`, arbitrary `/thread`
and resets remain user-invoked; bounded ask/research/plan/review/reply may belong to an approved flow.

## Prerequisites

- `codex` CLI on `PATH`; parent `exec` options on resume are checked with CLI 0.153.4.
- `~/.codex/config.toml` configured for an authorized model.
- Python 3.8+ for typed JSON events and process-group supervision.
- `setsid` or the Python fallback handles long-dispatch handoff.

Install:

```text
/plugin marketplace add clicktronix/cc-codex-triage
/plugin install cc-codex-triage@cc-codex-triage
```

The plugin never edits Codex rollout files under `~/.codex/sessions`.

## Controls and evidence

`review` and `plan` accept `--model` and `--effort`; explicit controls apply on
resume too. `ask` applies the read-only sandbox on every call. Omitted model/effort
use Codex configuration, not a promised model profile. `<thread>.last-usage.json`
records requested controls and observed token usage; dollar cost stays unknown.
A failed paid call may consume tokens even when its required-review slot is refunded.

Required mechanics live in [required-review.md](skills/codex-triage/references/required-review.md).
At cap or divergence, return the missing approval to the owner and continue safe
repairs; do not reset to seek a more favourable verdict. Existing valid test evidence
can be reused until its inputs change. No live model eval is implied by offline CI.

`research` accepts `--thread`, `--model`, `--effort`, and `--background`. It requests
live web search on each call using Codex's [web search configuration](https://developers.openai.com/codex/config-basic/#web-search),
uses the read-only shell sandbox, and returns cited conclusions with explicit limits.
Provider/tool availability is checked through actual research, not inferred from a flag.
The owner can supply missing evidence or write the requested report; research never
produces a required-review approval. Continue a study with the same research thread.

The internal skill routes requests, preserves task ownership and conversation history,
validates review findings, reuses current evidence, and defines handoff/recovery. An
already-authorized owner may invoke ask/research/plan/review/reply without another
permission question for each call, within the task and call budget. Debate, arbitrary
thread dispatch, reset, and the status/list slash commands remain user-invoked. Reading
existing state and logs is ordinary inspection. These invocation controls follow
[Claude Code skill frontmatter](https://code.claude.com/docs/en/skills).
