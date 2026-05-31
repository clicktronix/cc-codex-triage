---
description: Send a message to the persistent "review" Codex thread; creates one if none exists. Use to triage code, diffs, PRs, or another agent's findings.
argument-hint: <paste or question for Codex>
---

# /codex-review

Forwards `$ARGUMENTS` to the named Codex thread `review`, creating it on first use and resuming it on subsequent calls so Codex retains full context.

## Steps

1. Resolve the plugin's script directory and run:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" review <<< "$ARGUMENTS"
   ```

   (Use Bash tool, timeout 600000 — reviews can take several minutes.)

2. **Judge-mode check.** If `$ARGUMENTS` contains a review or critique from another agent (look for cues: "вот что нашёл агент", "review from", "findings:", paste of structured findings, bullet lists of issues with severities), wrap the prompt before piping:

   ```
   You are evaluating a third-party review.
   Below is the CODE in scope, then a REVIEW of that code by a different agent.
   For each finding in the review, classify as: valid (defensible by code+evidence)
   / borderline (style or judgement call) / invalid (refuted by code) / outdated
   (was once true, code has changed). Cite the file:line you used to decide.
   Do NOT accept claims at face value. If the review is mostly correct, say so;
   if it's mostly wrong, say so. End with a one-line overall verdict.

   --- CODE ---
   <the code in scope, or git diff>

   --- REVIEW ---
   $ARGUMENTS
   ```

   When the input is direct (own code/question, no third-party review), pass it through as-is.

3. Show Codex's reply verbatim to the user.

4. If the script exits with code 4 (resume failed), DO NOT auto-retry with `--new`. Tell the user, ask whether to start a fresh thread.

5. If the script exits with code 5 or warns about tracked-file mutations, surface the diff to the user — Codex touched files in the working tree.

## Notes

- Thread state at `.claude/codex-threads/review.id` and audit log `.claude/codex-threads/review.log`.
- Force-reset: `/codex-thread-new review` (loses memory of prior turns).
- For one-shot reviews with no follow-up planned, `hamelsmu/claude-review-loop` is the better fit. This command is for iterative triage.
