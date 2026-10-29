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
An already-authorized workflow may call every command except `/thread`, which stays
user-invoked. The owner retains tasks, fixes and delivery; the bridge does not create
backlog items. Details: [SKILL.md](skills/codex-triage/SKILL.md).

## Threads pane

In the Claude Code CLI (2.1.287 or later, which loads mods), the plugin's mod shows the
current context's Codex threads without a model turn: the threads whose state lives in
this session's working directory, so a dispatch started from another repository shows in
a session opened there.

`/codex-pane` opens a pane beside the transcript, asking for 48 columns; a width you set
wins. `ctrl+x tab` focuses it, `ctrl+x left` or `ctrl+x right` widens or narrows it. It
lists each thread with its rounds, last activity and topic; an in-flight dispatch comes
first with its round, running time and what Codex is doing now (the program it runs, the
file it edits, or that it is replying); required-review states follow. Under an idle
thread is the first line of its last reply, cut to the pane, with `+N lines` when there
is more. A reply with more to see opens whole in place when its thread or that line is
pressed (`Enter` once the pane has focus, or a click) and closes on a second press; a new
round of that thread replaces it. While a dispatch runs, one line above the prompt says
what the pane says; a toast reports when it ends.

To turn the pane off, run `/codex-pane` again or press `ctrl+x x` while it has focus. It
never opens by itself, so a closed pane stays closed. The band and the toast have no
switch of their own, since Claude Code has no setting for one plugin's mod: disabling the
plugin (`/plugin`, or `"cc-codex-triage@cc-codex-triage": false` under `enabledPlugins`)
removes them with its commands, and `disableAllHooks: true` also stops this mod, along with
other user-installed mods and hooks.

The mod only reads: the state directory through `$.fs`, the dispatch's Codex event
stream and each thread's log through `tail` (a log again only when it changes), and
`kill -0` on a lease PID. A command shows as its program alone (`npm …`), or for an
interpreter its script (`bash check.sh`), never its arguments. Reply text is on screen (a
first line per thread, the whole reply once opened) and command output never; everything
shown passes through `redact.sh`, which masks known key shapes only. The stream is
followed only at the driver's own `cc-codex-<thread>.XXXXXX.jsonl` name, and a stream or
log only as a regular file. It makes no network calls and draws nothing outside the
terminal, since `$.process` is CLI-only.

## Required review

Required review binds one exact clean candidate (base, tracked spec, HEAD, tree) to a
claimed round and accepts only a bare final `APPROVE` with a completed driver receipt.
Endpoint checks do not prove the filesystem was immutable during the call, so the owner
must keep the candidate stable. The full protocol is in
[required-review.md](skills/codex-triage/references/required-review.md).

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

Keep a thread until delivery and archive needed history before removing it. Explicit
resets archive prior state to `<thread>.archive.*`; `/status` reports archives and
nothing deletes them.

`--model` and `--effort` are accepted by every dispatching command and, like the sandbox,
are recorded per thread (see the skill's Threads section).
`<thread>.last-usage.json` and `<thread>.usage.jsonl` hold requested controls and token
usage; dollar cost stays unknown. Diagnostic tails mask API keys and tokens.

## What works where

| capability | Git repository | directory outside Git |
|---|---|---|
| `ask`, `research`, `debate`, `thread`, `reply` | yes | yes — state under `XDG_STATE_HOME` |
| `review` (advisory) | yes | yes, without a candidate |
| `review --required` (delivery gate) | yes | **no** — needs a clean HEAD/tree to bind to |
| `--search` live web search | `research` and `debate` request it on every call, initial and resumed; `ask`, `reply` and `thread` do not; availability is the provider's, per Codex's [web search configuration](https://developers.openai.com/codex/config-basic/#web-search) | same |
| `status`, `thread-list`, `thread-new` | yes | yes |

Tested in CI on Linux and macOS. Windows is untested (no `setsid`; the Python fallback would run).
The merge boundary lives in the host plugin (`cc-tuner`), not here.

## Permissions

Command frontmatter scopes pre-approved Bash to this plugin's executable scripts through
`${CLAUDE_PLUGIN_ROOT}`. It does not grant arbitrary Bash for the turn. These invocation
controls follow [Claude Code skill frontmatter](https://code.claude.com/docs/en/skills).

## Prerequisites

- `codex` CLI on `PATH`. `/status` shows its version.
- `~/.codex/config.toml` configured for an authorized model.
- Python 3.8+ (typed JSON events, process-group supervision); a missing interpreter exits 2 before dispatch.
- `setsid` or the Python fallback handles long-dispatch handoff.

Install:

```text
/plugin marketplace add clicktronix/cc-codex-triage
/plugin install cc-codex-triage@cc-codex-triage
```

The plugin never edits Codex rollout files under `~/.codex/sessions`.
