# cc-codex-triage plugin

Persistent named Codex CLI threads for open-ended cross-agent triage in Claude Code.

## What it gives you

- `/codex-review [paste]` — talk to the same Codex `review` thread across turns. Auto-wraps third-party reviews in Judge-mode framing.
- `/codex-plan [paste]` — same, for the `plan` thread.
- `/codex-thread <name> [message]` — arbitrary named threads.
- `/codex-thread-list` — show active threads + last-activity timestamps.
- `/codex-thread-new <name> [message]` — force-reset a thread (loses memory).
- Skill `codex-triage` documents when to invoke each command and how Judge mode framing suppresses sycophantic capitulation.

## How it differs from the alternatives

| | This plugin | `hamelsmu/claude-review-loop` | `dementev-dev/adversarial-review` |
|---|---|---|---|
| Codex sessions | **Persistent via `exec resume`** | Fresh each time | Persistent via `exec resume` |
| Round cap | **None — open-ended** | 1 | 5 (approve/revise) |
| Purpose | **Iterative triage dialogue** | Multi-agent one-shot review | Approve/revise fix loop |
| Output | Markdown stream, raw | Consolidated Markdown file | JSON + Markdown + VERDICT literal |

Use this when the conversation will iterate. Use `claude-review-loop` for a single comprehensive review. Use `adversarial-review` when you want a hard pass/fail gate after a bounded number of rounds.

## Prerequisites

- `codex` CLI ≥ 0.132.0 (`npm install -g @openai/codex`).
- `~/.codex/config.toml` with a model you're authorised for. Override per-call via `CC_CODEX_FLAGS="-m gpt-5.5 -s read-only"`.

## Where state lives

- `.claude/codex-threads/<name>.id` — saved Codex session UUID for the thread.
- `.claude/codex-threads/<name>.log` — append-only prompt/reply audit log.
- `~/.codex/sessions/rollout-*.jsonl` — Codex's own rollout files (managed by Codex CLI).

The plugin never deletes Codex's rollout files. `/codex-thread-new` only clears the local pointer.

## Safety primitives

- **No silent fresh exec on resume failure.** If `codex exec resume` fails, the driver exits 4 and asks you to `--new` explicitly. Your memory of "Codex remembers this" never silently breaks.
- **Tracked-file mutation guard.** The driver snapshots `git status --porcelain` pre/post each Codex dispatch and warns on diff. Set `CC_CODEX_TRIAGE_STRICT=1` to make it fatal. Run with `CC_CODEX_FLAGS="-s read-only"` for pure-review threads.
- **No `--last`.** Threads are pinned to their saved UUID; if it's gone, the next call starts fresh, not "whatever was most recently touched in `~/.codex/sessions/`".

## Judge-mode framing

When you paste another agent's findings into `/codex-review`, the command wraps the prompt as a third-party evaluation rather than sequential rebuttal. Empirically (arXiv 2509.16533, EMNLP 2025 Findings) this drops sycophantic capitulation rates from 23.5–80.3% down by 1.5–2×.

## Installation

```
/plugin add cc-codex-triage @clicktronix/cc-codex-triage
```

Or clone and install locally:

```
git clone https://github.com/clicktronix/cc-codex-triage ~/.claude/plugins/cc-codex-triage
```

## License

MIT.
