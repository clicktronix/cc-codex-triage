# cc-codex-triage plugin

Persistent Codex CLI conversations for Claude Code, scoped to a Git worktree or standalone directory.

## Commands

- `/ask`: informational question, read-only by default.
- `/research`: one research pass using primary sources, live web search and optional repository evidence.
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
`ask`, `research`, `plan`, `review`, `reply` and `debate` may be called by an already-authorized workflow.
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

`scripts/state-dir.sh` stores repository state under the current worktree's absolute Git
directory:

```text
<absolute-git-dir>/cc-codex-triage/threads/
```

Outside Git, state lives in `${XDG_STATE_HOME:-$HOME/.local/state}/cc-codex-triage/contexts/<sha256-of-physical-directory>/threads/`. No Git initialization or files in the working directory are needed. Use the same directory to continue, list or reset these conversations. Only required review needs a Git candidate.

Session ids are context-local by policy; the driver passes this checkout on resume
too. Keep it until delivery and archive needed history before removing it. Upgrading
0.11 to 0.12 preserves sessions, but old approvals need a fresh claimed round to acquire
a dispatch receipt. Earlier `.claude/codex-threads` and common-Git state are not migrated;
preserve any useful legacy logs before choosing a new thread.

Same-thread dispatches are serialized. A busy thread exits 10. Resume failure
exits 4 and preserves the saved id;
an owned idle advisory thread may be retired with `/thread-new`. Explicit resets preserve prior plugin state in a tar file at `<thread>.archive.*`. `/status` shows retained archive count, bytes and location; archives are not automatically deleted.
Reviewers run in separate process groups; cancellation signals the entire reviewer process group
without signalling the host terminal. Watcher timeout still hands off a live worker.

## What works where

| capability | Git repository | directory outside Git |
|---|---|---|
| `ask`, `research`, `debate`, `thread`, `reply` | yes | yes — state under `XDG_STATE_HOME` |
| `review` (advisory) | yes | yes, without a candidate |
| `review --required` (delivery gate) | yes | **no** — needs a clean HEAD/tree to bind to |
| `--search` live web search | `research` and `debate` request it on every call, initial and resumed; `ask`, `reply` and `thread` do not; availability is the provider's | same |
| `status`, `thread-list`, `thread-new` | yes | yes |

Tested in CI on Linux and macOS. Windows is untested: `setsid` is absent there and the Python
isolator path is the one that would run. GitHub is not assumed by this plugin; the merge boundary
lives in the host plugin (`cc-tuner`), not here. Nothing above is a promise about model behaviour;
offline tests cover transport and state.

## Permissions

Command frontmatter scopes pre-approved Bash to this plugin's executable
scripts through `${CLAUDE_PLUGIN_ROOT}`. It does not grant arbitrary Bash for
the turn. These grants do not remove other host tools. Bounded ask/research/plan/review/reply/debate
and owned thread maintenance may belong to an approved flow. Arbitrary `/thread` remains user-invoked.

## Prerequisites

- `codex` CLI on `PATH`. The CLI interface, including parent `exec` options on resume, was checked with 0.153.4; a minimum compatible version for this release has not been established. `/status` shows installed and reference versions without blocking calls.
- `~/.codex/config.toml` configured for an authorized model.
- Working Python 3.8+ for typed JSON events and process-group supervision. A local interpreter check rejects an unavailable runtime with exit 2 before dispatch changes thread state. Standalone status/list/reset also use Python to locate context state and report dependency failures with exit 2; Git-local maintenance does not require it.
- `setsid` or the Python fallback handles long-dispatch handoff.

Install:

```text
/plugin marketplace add clicktronix/cc-codex-triage
/plugin install cc-codex-triage@cc-codex-triage
```

The plugin never edits Codex rollout files under `~/.codex/sessions`.

## Controls and evidence

Every command that dispatches to Codex — `ask`, `research`, `review`, `plan`, `reply`,
`debate`, `thread` — accepts `--model` and `--effort`; explicit controls apply on
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
already-authorized owner may invoke ask/research/plan/review/reply/debate without another
permission question for each call, within the task and call budget. It can use status/list
and retire owned idle advisory threads with reset, retaining the archive. Preserve threads
needed by active tasks or required delivery. Reset clears the review lifecycle, including
its attempt count and approval; it grants no approval. Policy forbids reset to evade the
cap or unresolved findings. At the cap, continue safe work and report missing approval
once; starting another review budget requires user authorization, reusing it if already given.
Arbitrary `/thread` dispatch remains user-invoked. These invocation controls follow
[Claude Code skill frontmatter](https://code.claude.com/docs/en/skills).
