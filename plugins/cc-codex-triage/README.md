# cc-codex-triage plugin

Persistent named Codex CLI threads for open-ended cross-agent triage in Claude Code.

## What it gives you

- `/ask [--oneshot] <question>` — informational Q&A in the persistent `ask` thread (read-only sandbox). "How does X work here", "is there already a Y".
- `/review [--lens <name>] [--thread <name>] [--oneshot] <paste>` — critique in a review thread. Lenses: correctness (default), security, performance, architecture, ux, quick. Auto-wraps third-party reviews in Judge-mode framing; injects a round counter so Codex states how close the diff is to APPROVE.
- `/plan [--lens <name>] [--thread <name>] [--oneshot] <plan>` — stress-test in a plan thread. Lenses: stress-test (default), pre-mortem, devils-advocate, alternatives, adr.
- `/reply [thread] <directive>` — Claude Code replies back into an active thread (answer a question, run a requested tool action, push back on a finding).
- `/debate [--rounds N] <question>` — structured multi-round disagreement between Claude Code and Codex on a decision, every exchange visible to the user, ending in an honest synthesis (residual disagreements stated, not papered over).
- `/autoreview on|off|status` — on arming, if the branch already has changes it reviews them immediately (no manual `/review`); then a Stop hook blocks any future turn with unverified code changes until a Codex review reaches APPROVE (or the round cap). Runaway-safe: the numeric-validated round cap is the hard terminator (malformed state fails open), the APPROVE gate is the success release, branch+dirty scoping keeps it out of unrelated turns.
- `/autoplan on|off|status` — same gate for plan documents: a turn that changed `docs/plans/**` can't finish until the plan has been stress-tested at least once. Same cap semantics.
- `/thread [--oneshot] <name> <message>` — arbitrary named threads (plain passthrough).
- `/thread-list` — active threads + rounds, log size, last activity.
- `/thread-new <name> [message]` — force-reset a thread (loses memory).
- Skill `codex-triage` documents routing, Judge-mode framing, debate anti-capitulation rules, the fix-the-neighborhood rule, and the `--oneshot` modifier.

Every command keeps a persistent Codex thread by default; `--oneshot` makes any of them a throwaway (`codex exec --ephemeral`, no state kept). **One task = one thread**: pass `--thread review-<branch>` when starting a new task instead of reusing a default thread that already holds a different one.

## How it differs from the alternatives

| | This plugin | `hamelsmu/claude-review-loop` | `dementev-dev/adversarial-review` |
|---|---|---|---|
| Codex sessions | **Persistent via `exec resume`** | Fresh each time | Persistent via `exec resume` |
| Round cap | **Open-ended (capped only in `/autoreview` gate)** | 1 | 5 (approve/revise) |
| Purpose | **Iterative triage dialogue + opt-in self-verification gate** | Multi-agent one-shot review | Approve/revise fix loop |
| Output | Markdown stream, raw | Consolidated Markdown file | JSON + Markdown + VERDICT literal |

Use this when the conversation will iterate. Use `claude-review-loop` for a single comprehensive review. Use `adversarial-review` when you want a hard pass/fail gate after a bounded number of rounds.

## Prerequisites

- `codex` CLI ≥ 0.132.0 (`npm install -g @openai/codex`).
- `~/.codex/config.toml` with a model you're authorised for. Override per-call via `CC_CODEX_FLAGS="-m gpt-5.5 -s read-only"`.

## Where state lives

- `.claude/codex-threads/<name>.id` — saved Codex session UUID for the thread.
- `.claude/codex-threads/<name>.log` — append-only prompt/reply audit log.
- `~/.codex/sessions/rollout-*.jsonl` — Codex's own rollout files (managed by Codex CLI).

The plugin never deletes Codex's rollout files. `/thread-new` only clears the local pointer.

## Safety primitives

- **No silent fresh exec on resume failure.** If `codex exec resume` fails, the driver exits 4 and asks you to `--new` explicitly. Your memory of "Codex remembers this" never silently breaks.
- **Tracked-file mutation guard.** The driver snapshots `git status --porcelain` pre/post each Codex dispatch and warns on diff. Set `CC_CODEX_TRIAGE_STRICT=1` to make it fatal. Run with `CC_CODEX_FLAGS="-s read-only"` for pure-review threads.
- **No `--last`.** Threads are pinned to their saved UUID; if it's gone, the next call starts fresh, not "whatever was most recently touched in `~/.codex/sessions/`".

## Judge-mode framing

When you paste another agent's findings into `/review`, the command wraps the prompt as a third-party evaluation rather than sequential rebuttal. Empirically (arXiv 2509.16533, EMNLP 2025 Findings) this drops sycophantic capitulation rates from 23.5–80.3% down by 1.5–2×.

## Installation

```
/plugin marketplace add clicktronix/cc-codex-triage
/plugin install cc-codex-triage@cc-codex-triage
```

(The `@cc-codex-triage` suffix is the marketplace name — `plugin@marketplace`.)

Plugin commands are **namespaced** under the plugin. Invoke them as
`/cc-codex-triage:review`, `/cc-codex-triage:ask`, etc. The bare `/<name>` form
also works for names that don't collide with a built-in — but `/review` and
`/plan` are taken by Claude Code's own commands, so use the namespaced form for
those two.

## Scope: one-directional (Claude Code → Codex CLI)

This is a **Claude Code** plugin. Its slash commands shell out to the `codex`
CLI via the bundled driver. It is intentionally not packaged as a Codex plugin
(`.codex-plugin/`) — there is nothing for Codex to run; Codex is the callee, not
the host. If you want Codex to *host* skills, that is a different artifact.

## License

MIT.
