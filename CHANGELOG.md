# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

## [0.1.0] - 2026-05-31

### Added

- Initial release.
- `cc-codex-triage` Claude Code plugin scaffold (`.claude-plugin/marketplace.json` + `plugins/cc-codex-triage/.claude-plugin/plugin.json`).
- Skill `codex-triage` describing when to invoke each command, Judge-mode framing for third-party reviews (anti-sycophancy, arXiv 2509.16533), and known failure modes.
- Slash commands `/codex-review`, `/codex-plan`, `/codex-thread <name>`, `/codex-thread-list`, `/codex-thread-new <name>`.
- Bash driver `scripts/codex-thread.sh`:
  - Initial dispatch via `codex exec --json -o <out>` with session UUID extracted from JSONL stream (`thread_id` / `session_id` / `conversation_id` fields tried in order).
  - Subsequent turns via `codex exec resume --json <UUID> -o <out>`.
  - No silent fresh-exec fallback on resume failure (exit 4) — the saved UUID is preserved so the caller's memory does not break without explicit `--new`.
  - Tracked-file mutation guard: `git status --porcelain` snapshot pre/post each Codex dispatch, warn on diff (fatal if `CC_CODEX_TRIAGE_STRICT=1`).
  - Append-only audit log per thread at `.claude/codex-threads/<name>.log`.
- MIT license.
