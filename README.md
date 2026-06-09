# cc-codex-triage

Claude Code plugin for **persistent triage dialogue** with the OpenAI Codex CLI.

Adds slash commands `/ask`, `/review`, `/plan`, `/reply`, `/thread` that talk to **named Codex threads** via `codex exec resume <UUID>` — Codex retains full conversation memory across Claude Code turns. Unlike `claude-review-loop` (one-shot) or `adversarial-review` (5-round approve/revise fix loop), this plugin is for **open-ended cross-agent triage**: paste, ask follow-ups, dig in, no round cap.

Plus a skill (`codex-triage`) that frames third-party reviews in **Judge mode** to suppress sycophantic capitulation (arXiv 2509.16533).

This is a **Claude Code** plugin and is one-directional: its commands call the `codex` CLI. Codex is the callee, not the host — there is no `.codex-plugin/` packaging by design.

## Quick start

```
/plugin marketplace add clicktronix/cc-codex-triage
/plugin install cc-codex-triage@cc-codex-triage
```

Then in any repo. Commands are namespaced under the plugin — invoke as `/cc-codex-triage:<name>`. (The bare `/<name>` works too, except where it collides with a built-in: `/review` and `/plan` resolve to Claude Code's own commands, so use the namespaced form for those.)

```
/cc-codex-triage:review "here's a diff, what would you push back on?"
[paste diff]
```

Follow-up keeps the same Codex thread alive:

```
/cc-codex-triage:review "ok, the second finding — show me the failure case as a test"
```

See [`plugins/cc-codex-triage/README.md`](plugins/cc-codex-triage/README.md) for full details.

## Repo layout

```
.claude-plugin/marketplace.json       # marketplace manifest
plugins/
  cc-codex-triage/
    .claude-plugin/plugin.json        # plugin manifest
    README.md                         # plugin README (install + usage)
    skills/codex-triage/SKILL.md      # when to invoke + Judge mode
    commands/                         # invoked as /cc-codex-triage:<name>
      ask.md                          # :ask
      review.md                       # :review (--lens, --thread, round counter)
      plan.md                         # :plan (--lens, --thread, round counter)
      reply.md                        # :reply
      debate.md                       # :debate — CC vs Codex, user watches
      autoreview.md                   # :autoreview — Stop-hook code gate
      autoplan.md                     # :autoplan — Stop-hook plan gate
      thread.md                       # :thread <name>
      thread-list.md                  # :thread-list
      thread-new.md                   # :thread-new <name>
    hooks/hooks.json                  # Stop hook wiring
    hooks/stop-hook.sh                # self-verification gate (fail-open)
    scripts/codex-thread.sh           # bash driver — codex exec / exec resume
    skills/codex-triage/references/   # review/plan lens templates
  tests/scenarios/codex-triage/       # RED→GREEN eval scenarios
CHANGELOG.md
LICENSE                               # MIT
```

## Why a separate repo

This pattern (CLI resume + named thread state) is orthogonal to the architecture-and-conventions content in `nextjs-clean-skills`. It applies to **any** project and is opinionated about cross-agent workflow rather than about a stack, so it deserves its own publication and its own version bumps.

## License

MIT.
