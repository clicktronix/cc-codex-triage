---
description: Send a message to the persistent "review" Codex thread; creates one if none exists. Use to triage code, diffs, PRs, or another agent's findings.
argument-hint: <paste or question for Codex>
allowed-tools: Bash
disable-model-invocation: true
---

# /codex-review

Forwards `$ARGUMENTS` to the named Codex thread `review`, creating it on first use and resuming it on subsequent calls so Codex retains full context.

## Steps

1. **Apply Judge-mode framing per skill `codex-triage`** if `$ARGUMENTS` looks like a third-party review or critique (see the skill for detection cues and the exact wrapping template). For direct questions, pass through unwrapped.

2. Run via Bash tool (timeout 600000 — reviews can take several minutes):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" review <<< "$PROMPT_BODY"
   ```

   Where `$PROMPT_BODY` is either the wrapped Judge-mode prompt from step 1 or the raw `$ARGUMENTS`.

3. Show Codex's reply verbatim to the user.

4. If the script exits with **code 4** (resume failed), DO NOT auto-retry with `--new`. Tell the user, ask whether to start a fresh thread.

5. If the script exits with **code 5** or warns about tracked-file mutations, surface the diff to the user — Codex touched files in the working tree.

## Notes

- Thread state at `.claude/codex-threads/review.id`; audit log `.claude/codex-threads/review.log`.
- Force-reset: `/codex-thread-new review` (loses memory of prior turns).
