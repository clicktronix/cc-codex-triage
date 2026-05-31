# cc-codex-triage

Claude Code plugin for **persistent triage dialogue** with the OpenAI Codex CLI.

Adds slash commands `/codex-review`, `/codex-plan`, `/codex-thread` that talk to **named Codex threads** via `codex exec resume <UUID>` — Codex retains full conversation memory across Claude Code turns. Unlike `claude-review-loop` (one-shot) or `adversarial-review` (5-round approve/revise fix loop), this plugin is for **open-ended cross-agent triage**: paste, ask follow-ups, dig in, no round cap.

Plus a skill (`codex-triage`) that frames third-party reviews in **Judge mode** to suppress sycophantic capitulation (arXiv 2509.16533).

## Quick start

```
/plugin add cc-codex-triage @clicktronix/cc-codex-triage
```

Then in any repo:

```
/codex-review "here's a diff, what would you push back on?"
[paste diff]
```

Follow-up keeps the same Codex thread alive:

```
/codex-review "ok, the second finding — show me the failure case as a test"
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
    commands/
      codex-review.md                 # /codex-review
      codex-plan.md                   # /codex-plan
      codex-thread.md                 # /codex-thread <name>
      codex-thread-list.md            # /codex-thread-list
      codex-thread-new.md             # /codex-thread-new <name>
    scripts/codex-thread.sh           # bash driver — codex exec / exec resume
CHANGELOG.md
LICENSE                               # MIT
```

## Why a separate repo

This pattern (CLI resume + named thread state) is orthogonal to the architecture-and-conventions content in `nextjs-clean-skills`. It applies to **any** project and is opinionated about cross-agent workflow rather than about a stack, so it deserves its own publication and its own version bumps.

## License

MIT.
