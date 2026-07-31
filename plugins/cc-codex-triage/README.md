# cc-codex-triage plugin

**English** · [Español](README.es.md) · [Русский](README.ru.md)

Persistent named Codex CLI threads for open-ended cross-agent triage in Claude Code.

## What it gives you

- `/ask [--thread <name>] [--oneshot] <question>` — informational Q&A in a persistent thread (read-only sandbox by default). "How does X work here", "is there already a Y". Defaults to the repo-wide `ask` thread; pass `--thread <feature>` to keep a feature's questions with the rest of that feature's Codex context.
- `/review [--lens <name>] [--thread <name>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] [--json] [--continue] <paste>` — critique in a review thread; **iterates to APPROVE by default** (dispatch → fix → re-review until APPROVE or `--cap` rounds), `--once` for a single pass. Lenses: correctness (default), security, performance, architecture, ux, quick. Default thread is branch-scoped (`review-<branch>`). A pasted third-party review is auto-wrapped in Judge-mode as a single classification pass (no loop). `--model`/`--effort` set the model/reasoning effort, applied on the initial or `--oneshot` dispatch only (a resume keeps the thread's model/effort stable and WARNs if you pass them again). `--background` dispatches detached and returns the turn without waiting (implies a single pass, no loop; uses the driver's `--detach` — the dispatch runs in its own session, surviving harness process-reaping — plus the bundled `detach-watch.sh` watcher run as a Claude-managed background task, which delivers the reply or the failure diagnostics as a completion notification). `--json` returns structured output (`schemas/review-output.schema.json`, needs `codex` ≥ 0.142 + `jq`) instead of prose, rendered to a human view and auto-recorded in the ledger with a confidence score per finding; it cannot release the text-mode `/autoreview` gate. Findings are recorded in a machine-readable, fail-closed ledger (`<thread>.findings.jsonl`, needs `jq` — a corrupt ledger is refused by readers and writers alike, never rendered empty or appended onto); `--continue` rebuilds the next round from the still-open findings + the diff since the last APPROVE.
- `/plan [--lens <name>] [--thread <name>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] <plan>` — stress-test in a plan thread; **iterates to APPROVE by default**. Lenses: stress-test (default), pre-mortem, devils-advocate, alternatives, adr. Plan lenses now end in a machine verdict (`APPROVE | REQUEST_CHANGES | COMMENT`). `--model`/`--effort` set the model/reasoning effort, applied on the initial or `--oneshot` dispatch only (a resume keeps the thread's model/effort stable and WARNs if you pass them again). `--background` dispatches detached and returns the turn without waiting (implies a single pass, no loop; uses the driver's `--detach` — the dispatch runs in its own session, surviving harness process-reaping — plus the bundled `detach-watch.sh` watcher run as a Claude-managed background task, which delivers the reply or the failure diagnostics as a completion notification).
- `/reply [thread] <directive>` — Claude Code replies back into an active thread (answer a question, run a requested tool action, push back on a finding).
- `/debate [--rounds N] [--thread <name>] <question>` — structured multi-round disagreement between Claude Code and Codex on a decision, every exchange visible to the user, ending in an honest synthesis (residual disagreements stated, not papered over).
- `/autoreview on|off|status` — on arming, if the branch already has changes it reviews them immediately (no manual `/review`); then a Stop hook blocks any future turn whose code differs from the last state the gate released, until a Codex review reaches an APPROVE **covering that state**, or the round cap. The unit is a **cycle**, not an arming: the fingerprint hashes working-tree *content*, so a fix survives its own commit and keeps the gate engaged, committing already-approved bytes costs no round, and one APPROVE releases one state rather than the whole arming. Runaway-safe: the numeric-validated per-cycle round cap is the hard terminator (malformed state fails open), refilled only by a real release. Armed gates **auto-expire after 14 days** — a stale gate on a long-merged branch removes itself instead of re-firing when the branch name is reused.
- `/autoplan on|off|status` — same as `/autoreview` but for plan documents: on arming, if `docs/plans/**` already changed it stress-tests them immediately; then blocks any future turn whose plan docs differ from the last released state until the plan thread has seen a dispatch in this cycle (the gate detects log growth, not command identity). The fingerprint hashes untracked file *content*, so a plan rewritten after a release re-engages the gate. Same cap and 14-day auto-expiry semantics.
- `/thread [--oneshot] <name> <message>` — arbitrary named threads (plain passthrough).
- `/thread-list` — active threads + rounds, log size, last activity.
- `/thread-new <name> [message]` — force-reset a thread (loses memory).
- `/status` — one-screen, read-only view: branch, dirty tree, armed gates (with stale-branch / pre-0.5 / missing-target warnings), last verdict per thread, gitignore status, and the Codex CLI version vs the required minimum.
- `/cleanup [--apply] [--older-than <days>]` — find stale/pre-0.5 armed gates, orphan thread logs, stale last-error diagnostics, and — with `--older-than <days>` — whole dormant threads; dry-run by default, `--apply` **archives** them (never deletes, reversible). Safety rails apply to every class: threads with a live dispatch lease (`<thread>.active` naming a live PID) or targeted by an armed gate are never touched, and generic `review`/`plan` threads are listed but never auto-archived. On `--apply` each thread's rail re-check and moves run under the SAME acquisition mutex (`<thread>.active.lock`) the driver uses to grant leases — a dispatch starting mid-archive is refused (exit 10, retry shortly) instead of racing the moves.
- `/review-dispute <id> <why>` / `/review-accept <id> --reason` / `/review-defer <id> --issue` — dispose of a recorded review finding by id (false-positive / accepted trade-off / deferred to a tracked issue), so it leaves the open list with an audit trail instead of being silently dropped.
- Skill `codex-triage` documents routing, Judge-mode framing, debate anti-capitulation rules, validating inbound Codex findings (verify before you apply — don't rubber-stamp to release the gate), the fix-the-neighborhood rule, when the review loop is the wrong tool, and the `--oneshot` modifier.
- Skill `codex-second-opinion` is the one part Claude may invoke **itself**: a single bounded dispatch when it is stuck at a fork the repository cannot settle, about to do something irreversible, or looking at two sources that contradict each other. It announces the cost before spending it, spends exactly one dispatch, and never touches a `review-<branch>` gate thread. Everything iterative stays under your control — every slash command here is `disable-model-invocation`.

Every command keeps a persistent Codex thread by default; `--oneshot` makes any of them a throwaway (`codex exec --ephemeral`, no state kept). **One task = one thread**: `/review` and `/plan` default to a branch-scoped thread (`review-<branch>` / `plan-<branch>`, e.g. `review-main` on `main` — no main special-case), so each branch and its matching gate stay isolated; pass `--thread <topic>` to split further, or `--thread review` for a shared one.

**One feature = one thread, across commands.** Those defaults are per *command kind*, so a feature's context splits between `ask`, `plan-<branch>` and `debate-<slug>`. Point `/ask`, `/plan` and `/debate` at a single `--thread <feature>` and leave `/review` on its branch thread (the gate reads verdicts there). The sandbox is fixed when a Codex session is created — `codex exec resume` takes `-m` and `--output-schema` but no `-s` — so a feature thread picks read-only or write once, on the first dispatch. And since every resume re-feeds the history, split past ~10 rounds or ~100 KB (`/thread-list` shows both) rather than resuming indefinitely.

## How it differs from the alternatives

| | This plugin | `hamelsmu/claude-review-loop` | `dementev-dev/adversarial-review` |
|---|---|---|---|
| Codex sessions | **Persistent via `exec resume`** | Fresh each time | Persistent via `exec resume` |
| Round cap | **`--cap` per loop (default 5), separate per-cycle cap in the gates** | 1 | 5 (approve/revise) |
| Purpose | **Iterative triage dialogue + opt-in self-verification gate** | Multi-agent one-shot review | Approve/revise fix loop |
| Output | Markdown stream, raw | Consolidated Markdown file | JSON + Markdown + VERDICT literal |

Use this when the conversation will iterate. Use `claude-review-loop` for a single comprehensive review. Use `adversarial-review` when you want a hard pass/fail gate after a bounded number of rounds.

## Prerequisites

- `codex` CLI ≥ 0.137.0 (`npm install -g @openai/codex`) — the version the resume/`--ephemeral` semantics were verified on; older CLIs may work but are untested.
- `/review --json` needs `codex` ≥ 0.142 (`--output-schema` support) and `jq`.
- `~/.codex/config.toml` with a model you're authorised for. Override per-call via `CC_CODEX_FLAGS="-m gpt-5.5 -s read-only"`. Limitation: the flags string is split on whitespace, so individual flag values cannot contain spaces.
- Same-thread dispatches are serialized by the driver: a second dispatch while one is in flight is refused (exit 10, PID lease + acquisition mutex) — it cannot race the counters/log. Still keep one Claude Code session per repo at a time: gate arming files and the findings ledger are written by command steps outside the driver's lease, so two sessions working the same repo can overwrite each other's gate/ledger state (last writer wins).

## Where state lives

- `.claude/codex-threads/<name>.id` — saved Codex session UUID for the thread.
- `.claude/codex-threads/<name>.log` — append-only prompt/reply audit log.
- `~/.codex/sessions/rollout-*.jsonl` — Codex's own rollout files (managed by Codex CLI).

The plugin never deletes Codex's rollout files. `/thread-new` only clears the local pointer.

## Safety primitives

- **No silent fresh exec on resume failure.** If `codex exec resume` fails, the driver exits 4 and asks you to `--new` explicitly. Your memory of "Codex remembers this" never silently breaks.
- **Tracked-file mutation guard.** The driver snapshots `git status --porcelain` pre/post each Codex dispatch and warns on diff. Set `CC_CODEX_TRIAGE_STRICT=1` to make it fatal. Run with `CC_CODEX_FLAGS="-s read-only"` for pure-review threads.
- **No `--last`.** Threads are pinned to their saved UUID; if it's gone, the next call starts fresh, not "whatever was most recently touched in `~/.codex/sessions/`".

### Known over-grant: `allowed-tools: Bash`

Every command here declares a bare `allowed-tools: Bash`. That field is a
**pre-approval grant, not a restriction** — so for the turn that invokes one of
these commands, any Bash command runs without a permission prompt, not just the
plugin's driver. It should be scoped to the driver invocation.

It is not scoped yet, deliberately. The documented substitutions inside
`allowed-tools` Bash rules are `${CLAUDE_SKILL_DIR}` and `${CLAUDE_PROJECT_DIR}`;
`${CLAUDE_PLUGIN_ROOT}` — which is what every command actually invokes through —
is not among them. A rule written against it would most likely stay a literal
string, match nothing, and turn every dispatch into a permission prompt. Trading
a narrow over-grant for a broken flow is a bad deal, so this waits on either
confirming `${CLAUDE_PLUGIN_ROOT}` expands there, or rewriting the rules against
`${CLAUDE_SKILL_DIR}`.

The grant lasts only for the turn that invoked the command and clears on your
next message.

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
