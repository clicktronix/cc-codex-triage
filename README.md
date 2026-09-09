# cc-codex-triage

Claude Code plugin for persistent, named conversations with OpenAI Codex CLI.
It keeps named threads and exact-candidate required approval, with bounded
review loops and long-review handoff. General research/debate also work outside Git. Requires Python 3.8+ and Codex CLI.
Ask/research/plan/review/reply/debate support bounded calls from an authorized owning workflow.

## Install

```text
/plugin marketplace add clicktronix/cc-codex-triage
/plugin install cc-codex-triage@cc-codex-triage
```

Use commands through the namespace, for example:

```text
/cc-codex-triage:review review this branch for correctness
/cc-codex-triage:plan --lens pre-mortem wiki/PLANS/change.md
/cc-codex-triage:ask --thread feature-x how is retry state represented?
/cc-codex-triage:research --thread job-recovery compare recovery approaches using current docs and this repository
```

The available commands are `/ask`, `/research`, `/review`, `/plan`, `/reply`, `/debate`,
`/thread`, `/thread-list`, `/thread-new`, and `/status`. See the
[plugin README](plugins/cc-codex-triage/README.md) for contracts and state.

## Repository layout

```text
plugins/cc-codex-triage/
  .claude-plugin/plugin.json
  commands/
  skills/codex-triage/
  scripts/
tests/
  driver-regression.sh
  review-contract-regression.sh
  manifest-lint.sh
  product-integrity.py
  run.sh
  scenarios/
wiki/PLANS/
```

The scenario files are historical prompt evidence. Deterministic shell tests
cover the product routes and required gate.

## Development

```bash
bash tests/run.sh
```

This repository intentionally packages a Claude Code plugin only. Codex CLI is
the callee, not the host.

## License

MIT.
