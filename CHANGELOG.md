# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

## [0.3.0] - 2026-06-08

### Changed (BREAKING)

- **Dropped the `codex-` prefix from all command names.** Plugin commands are namespaced under the plugin anyway (`/cc-codex-triage:codex-review` had "codex" twice), so the prefix was redundant in the form you actually invoke. New names:
  - `/cc-codex-triage:ask` (was `codex-ask`)
  - `/cc-codex-triage:review` (was `codex-review`)
  - `/cc-codex-triage:plan` (was `codex-plan`)
  - `/cc-codex-triage:reply` (was `codex-reply`)
  - `/cc-codex-triage:thread` / `:thread-list` / `:thread-new` (was `codex-thread*`)
  - Command files renamed accordingly; docs, skill routing table, and scenarios updated.
  - The skill (`codex-triage`), the driver (`scripts/codex-thread.sh`), and the thread state dir (`.claude/codex-threads/`) are **unchanged** — existing threads (`review.id`, `plan.id`, …) keep working after re-install; only the slash-command names changed.
  - **Note on bare forms:** `/review` and `/plan` now collide with Claude Code's built-in commands, so use the namespaced `/cc-codex-triage:review` / `:plan`. `/ask`, `/reply`, `/thread*` have no known collision.

## [0.2.2] - 2026-06-08

Minor tails from the Codex agent's re-review of v0.2.1 (it confirmed all v0.2.1
blockers fixed and `claude plugin tag --dry-run` now passing).

### Fixed

- **Accuracy: resume flag claims.** `codex exec resume` accepts `-m`/`-c` on current Codex CLIs (verified on 0.137.0); only `-s` (sandbox) and `-C` (cwd) are genuinely fixed at session creation. Reworded the driver comment, SKILL.md, scenario, and 0.2.0 changelog line which had said resume "rejects -m/-c". Runtime was already correct (the driver intentionally passes no overrides on resume to keep the thread stable) — only the wording was off.
- **`--oneshot` no longer creates an empty state dir.** The driver created `.claude/codex-threads/` before branching, so a one-shot left an empty directory despite "leaves no trace". The state dir is now created lazily for persistent modes only; a one-shot's failure diagnostics go to a temp path instead.

## [0.2.1] - 2026-06-08

Fixes from a cross-agent review (Codex audited the repo; findings validated
side-by-side against the code, then fixed). 8 of 9 findings were valid.

### Fixed

- **Blocker — broken command frontmatter.** `argument-hint` values starting with `[` were parsed by YAML as a flow sequence, failing the whole frontmatter so `claude plugin validate <plugin-dir>` dropped all metadata (including `allowed-tools` and `disable-model-invocation`) on 5 of 7 commands. All `argument-hint` values are now quoted. (My earlier validation only checked the marketplace manifest, not the plugin dir — now both pass `--strict`.)
- **Blocker — driver crashed on default run.** `"${EXTRA_FLAGS[@]}"` is an "unbound variable" under `set -u` on bash 3.2 (macOS default) when `CC_CODEX_FLAGS` is empty, so `/codex-review`, `/codex-plan`, `/codex-thread` never reached Codex without a custom env var. Switched to the `${arr[@]+"${arr[@]}"}` guard; verified on bash 3.2.57.
- **Mutation guard false positives on its own state dir.** `git status --porcelain` flagged the driver's own `.claude/codex-threads/*.id` writes. The guard now filters that directory and uses `-uall` so the filter survives git's untracked-dir collapse. Verified it still catches a real tracked-file mutation. Also fixed `.gitignore` (`.codex-threads/` → `.claude/codex-threads/`).
- **Diagnostics deleted before they could be read.** Error messages pointed at the JSONL stream, but the EXIT trap removed it. Failures now persist the stream to `<thread>.last-error.jsonl` and point there.
- **`--oneshot` now truly traceless.** It previously still wrote the audit log; the log write is now skipped for one-shots (no `.id`, no `.log`, no rollout).
- **`/codex-reply` no longer silently creates a thread.** New driver flag `--require-existing` (exit 6) makes reply fail-fast when the target thread doesn't exist.
- **Log rotation kept the latest entry.** Rotation now runs *before* the append, so the current `.log` always holds the newest `REPLY:` (previously the fresh entry was moved straight to `.log.1`).

### Documentation

- Corrected install instructions: `/plugin marketplace add clicktronix/cc-codex-triage` + `/plugin install cc-codex-triage@cc-codex-triage` (was the outdated `/plugin add`). Documented that plugin commands are namespaced (`/cc-codex-triage:codex-review`).
- Documented the porcelain guard's known limitation (already-dirty files), and clarified scope: this is a one-directional Claude Code → Codex plugin, intentionally not packaged as a Codex plugin.

### Known / not fixed

- `claude plugin tag --dry-run` reported failing in the review — that is a marketplace-tagging step, separate from plugin validity; deferred.

## [0.2.0] - 2026-06-01

### Added

- `/codex-ask` — informational Q&A in a persistent `ask` thread, defaulting the Codex sandbox to read-only (you're asking, not mutating; never trips the tracked-file guard). Supports `--oneshot`.
- `/codex-reply` — compose a reply from Claude Code back into an active Codex thread (answer a question, run a requested tool action, push back on a finding). Recovers Codex's last message from the thread log.
- `--lens` on `/codex-review` (correctness/security/performance/architecture/ux/quick) and `/codex-plan` (stress-test/pre-mortem/devils-advocate/alternatives/adr). Lens templates live in `skills/codex-triage/references/review-lenses.md` (progressive disclosure). Review lenses share a Conventional Comments output contract + verdict.
- `--oneshot` flag on the driver and all dispatch commands — throwaway via `codex exec --ephemeral`: no `.id` tracked, no rollout persisted. Mutually exclusive with `--new`.
- Skill section "Answering Codex back" and routing table (which command for which intent) in `SKILL.md`. Description broadened to cover asking and replying.
- New scenario `tests/scenarios/codex-triage/reply-tool-request.json`.

### Changed

- `SKILL.md` clarifies that Codex is an agent (it fetches diffs / runs tests itself) — send intent + scope + focus, not project context.
- Driver `--oneshot` branch reuses the porcelain guard and audit log; resume dispatches pass no overrides (sandbox/cwd are fixed at session creation; model/config kept stable across the thread).

### Eval

RED baselines run for the new `/codex-reply` claim (sonnet+neutral, haiku+adversarial; GREEN cells too):

- `reply-tool-request` — **UNREPRODUCIBLE** on the happy path. With a working tool call, both models run the requested command and paste verbatim output unprompted, and neither re-affirms Codex's self-retracted claim. The "Answering Codex back" section was therefore **demoted** from a load-bearing rule to a brief reminder (same treatment as `thread-id-extraction` and `rsc-hybrid-read` before it). A narrower unhappy-path failure (tool fails → guess instead of debug) is noted but untested.

Net across all four scenarios: only `resume-failure-handling` is a consistent RED. The lens templates are canned prompts, not behavioural claims, so they carry no RED requirement.

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

Self-reviewed against superpowers `writing-skills`, the Anthropic skill-authoring best practices document bundled with it, and the official Claude Code [skills](https://code.claude.com/docs/en/skills) and [plugins-reference](https://code.claude.com/docs/en/plugins-reference) docs. The review surfaced three Critical, eight Major, and ten lesser issues; all were addressed.

RED baselines for the three scenarios were then run against fresh subagents (sonnet+neutral and haiku+adversarial cells, CWD-isolated):

- `judge-mode-paste`: **INCONSISTENT**. Both models construct side-by-side judge framing on their own. The narrow failure that survives is Sonnet+neutral adding "provide a corrected implementation" at the end. SKILL.md was rewritten to specifically forbid that fix-application addendum rather than to teach the side-by-side framing (which neither model needs).
- `resume-failure-handling`: **CONSISTENT RED** under haiku+adversarial. The skill's Common Failure Modes row earns its place specifically for that audience.
- `thread-id-extraction`: **UNREPRODUCIBLE**. Both models independently derive the right architecture even under lazy framing. No SKILL.md section was added — the driver script is the only artifact. Scenario retained as design documentation (precedent: `rsc-hybrid-read` in `nextjs-clean-skills` v1.3 was demoted under the same pattern).

GREEN cells (skill loaded) are the natural v0.2 follow-up — confirm the skill flips the haiku+adversarial resume-failure behaviour and the sonnet+neutral fix-addendum.
