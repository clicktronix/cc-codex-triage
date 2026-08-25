# cc-codex-triage plugin

Persistent, worktree-local Codex CLI conversations for Claude Code.

## Commands

- `/ask`: informational question, read-only by default.
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

## Required review

Required review captures a clean candidate's canonical base, tracked spec,
HEAD, and tree before dispatch. It accepts only one bare final `APPROVE` from
the claimed foreground round. Candidate movement, a dirty worktree, wrong
prompt scope, background execution, no decision, cap exhaustion, or a failed
attribution cannot produce approval.

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

A resumed Codex session keeps the cwd selected at creation, so session ids are
never shared between worktrees. Removing a linked worktree removes its plugin
state. This release does not migrate `.claude/codex-threads` or earlier
common-Git state; start fresh threads after upgrading.

Same-thread dispatches are serialized. A busy thread exits 10. Resume failure
exits 4 and preserves the saved id until the user explicitly chooses
`/thread-new`.

## Permissions

Command frontmatter scopes pre-approved Bash to this plugin's executable
scripts through `${CLAUDE_PLUGIN_ROOT}`. It does not grant arbitrary Bash for
the turn. Paid commands other than `/review` remain user-invoked.

## Prerequisites

- `codex` CLI >= 0.137.0 on `PATH`.
- `~/.codex/config.toml` configured for an authorized model.
- `setsid` or `python3` only when detached delivery is needed.

Install:

```text
/plugin marketplace add clicktronix/cc-codex-triage
/plugin install cc-codex-triage@cc-codex-triage
```

The plugin never edits Codex rollout files under `~/.codex/sessions`.
