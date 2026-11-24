---
description: Reviews existing code, a diff, a branch or a pasted third-party review in a persistent Codex thread. Use --required only when an owning workflow needs machine-checked approval for one exact clean candidate.
argument-hint: '[--required --base <ref> --spec <path>] [--lens <name>] [--thread <name>] [--once] [--oneshot] [--cap N] [--background] [--model <m>] [--effort <e>] <intent or focus>'
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh *)
---

# /review

Send intent, scope and test evidence per the skill's Prompt boundary.

## Options

- Use `--thread <name>` or the ongoing review's known thread. For a new persistent
  review, run `${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh review`. Exit 8 lists
  a legacy contract whose branch is uncertain. Ask once which thread to use.
  An ephemeral call can use the name `review`.
- `--lens correctness|security|performance|architecture|ux|quick`: default
  `correctness`. Read the matching short prompt from
  `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md` on the
  initial round.
- Parse `--once`, `--oneshot` and `--background` as defined in the shared skill.
  Set `ONESHOT=1` for an ephemeral call and leave it empty otherwise. Forward explicit model and effort.
- `--cap N` sets the round limit, 7 by default. Required review pins its first cap (1–7):
  omit `--cap` on resume. An advisory review stores no count: count this invocation's rounds.
  After a lost context recount them in the thread log (`/status` prints the state directory):
  this invocation's first prompt, the one that carries the lens contract, and each later prompt
  that reports what changed. Another command's turn on the thread is not a round. When the log
  cannot show which prompts are this invocation's, tell the user the count is unknown.
- `--required --base <ref> --spec <path>` selects the foreground exact-candidate
  protocol. Reject `--required` combined with `--once`, `--oneshot` or `--background` before dispatch.

## Advisory review

1. On the first round, send the chosen lens. On later rounds say what changed
   and ask Codex to re-check earlier findings before looking for new ones.
   A pasted third-party review follows the skill's Reviews section (one classification pass).

2. Use Bash with `run_in_background: true` when requested. Run this recipe once per pass:

   ```bash
   [[ -n "$ONESHOT" ]] || "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" advisory-check "$THREAD" || exit $?
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" ${ONESHOT:+--oneshot} \
     ${MODEL:+--model "$MODEL"} ${EFFORT:+--effort "$EFFORT"} <<< "$PROMPT"
   ```

   On a non-zero exit, act per the Exit codes table of the skill `codex-triage`.

3. Validate every finding against the cited code and its consumers. Apply only
   valid findings. Push back with file:line evidence when a claim is wrong.
   Follow the shared skill's ownership contract for fixes, missing decisions and evidence.

4. Finish on `APPROVE`, on `COMMENT` with no blockers, or after one pass with `--once` or `--oneshot`. Otherwise iterate within the remaining rounds. At the cap, return outstanding findings and
   continue safe repairs; a required review follows "At the cap" in required-review.md.

## Required review

Read `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/required-review.md`
for `--required`. Record each completed verdict on the reviewed SHA before the first edit or commit, including `REQUEST_CHANGES`.
