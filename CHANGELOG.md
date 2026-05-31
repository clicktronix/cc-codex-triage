# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

## [0.1.0] - 2026-05-31

### Added

- `cc-codex-triage` Claude Code plugin scaffold (`.claude-plugin/marketplace.json` + `plugins/cc-codex-triage/.claude-plugin/plugin.json`).
- Skill `codex-triage` describing when to invoke each command, Judge-mode framing rule for third-party reviews (with detection cues and wrapping template), and a Common Failure Modes table covering resume failure, mid-thread sandbox change, `--last` contamination, tracked-file mutation, and sycophantic capitulation.
- Slash commands `/codex-review`, `/codex-plan`, `/codex-thread <name>`, `/codex-thread-list`, `/codex-thread-new <name>`. Each declares `allowed-tools: Bash` and `disable-model-invocation: true` so Claude never auto-fires them.
- Bash driver `scripts/codex-thread.sh`:
  - Initial dispatch via `codex exec --json -C "$CLAUDE_PROJECT_DIR (or pwd)" -o <out>` with strict UUID extraction (`8-4-4-4-12`) from JSONL stream (`thread_id` / `session_id` / `conversation_id` tried in order).
  - Subsequent turns via `codex exec resume --json <UUID> -o <out>` — no `-s`/`-m`/`-c`/`-C` passed (session-immutable).
  - No silent fresh-exec fallback on resume failure (exit code 4) — saved UUID is preserved.
  - Tracked-file mutation guard: `git status --porcelain` snapshot pre/post each Codex dispatch, warn on diff (fatal if `CC_CODEX_TRIAGE_STRICT=1`).
  - Per-thread audit log at `.claude/codex-threads/<name>.log`, rotated at ~1 MB (configurable via `CC_CODEX_TRIAGE_LOG_CAP_BYTES`).
  - Portable `mktemp` (works on macOS BSD and GNU coreutils).
- `tests/scenarios/codex-triage/` — three RED→GREEN scenarios scaffolded under the same contract used by `nextjs-clean-skills/tests/scenarios/`:
  - `judge-mode-paste.json` — guards the Judge-mode framing rule (anti-sycophancy on third-party review paste).
  - `resume-failure-handling.json` — guards "no silent fresh-exec on resume failure" (exit code 4 semantics).
  - `thread-id-extraction.json` — guards the driver's UUID capture from `--json` stdout (no `--last` fallback).
  - Each scenario has `baseline_observed: null` — the skill claims they guard are formally hypotheses until the baselines are reproduced. `tests/scenarios/README.md` documents the format and the run loop.
- MIT license.

### Authoring notes

This v0.1.0 was self-reviewed against superpowers `writing-skills`, the Anthropic skill-authoring best practices document bundled with it, and the official Claude Code [skills](https://code.claude.com/docs/en/skills) and [plugins-reference](https://code.claude.com/docs/en/plugins-reference) docs before this initial commit. The review surfaced three Critical, eight Major, and ten lesser issues; all were addressed prior to the first push. The RED baselines for the three scenarios above have NOT yet been run — until they are, the load-bearing claims in `SKILL.md` (Judge-mode framing, resume-failure handling, thread_id extraction) remain hypotheses per the Iron Law. They are kept in the skill body for now because the rationale is documented (sycophancy paper, Codex CLI session semantics); if the baselines turn out to be unreproducible, they should be demoted to prose (precedent: `rsc-hybrid-read` in `nextjs-clean-skills` v1.3).
