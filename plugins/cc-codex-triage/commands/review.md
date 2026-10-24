---
description: Reviews existing code, a diff, a branch or a pasted third-party review with a persistent Codex thread. Use --required only when an owning workflow needs machine-checked approval for one exact clean candidate. For a plan or design not yet implemented use /plan; for a question about how code works use /ask.
argument-hint: '[--required --base <ref> --spec <path>] [--lens <name>] [--thread <name>] [--once] [--cap N] [--background] [--model <m>] [--effort <e>] <intent or focus>'
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh *)
---

# /review

Send intent, scope and test evidence per the skill's Prompt boundary.

## Options

- `--thread <name>`: explicit thread. Otherwise run
  `${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh review`.
- `--lens correctness|security|performance|architecture|ux|quick`: default
  `correctness`. Read the matching short prompt from
  `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md` on the
  initial round.
- `--once`: one advisory pass. Without it, address validated blocking findings
  and resume until `APPROVE` or the cap.
- `--model <m>`, `--effort <e>`: forwarded when supplied; the skill defines how a thread keeps them.
- `--cap N`: maximum claimed review attempts, default 5 (1–5 for `--required`).
  `--cap` bounds claims, not Codex calls: a refunded dispatch may still have cost tokens.
- `--background`: see the skill's Long dispatches; never gate-eligible.
- `--required --base <ref> --spec <path>`: one foreground delivery-gate round.
  It cannot combine with `--once` or `--background`.

## Advisory review

1. On the first round, send the chosen lens. On later rounds say what changed
   and ask Codex to re-check earlier findings before looking for new ones.
   A pasted third-party review follows the skill's Reviews section (one classification pass).

2. Dispatch in the foreground:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" advisory-check "$THREAD" || exit $?
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" \
     ${MODEL:+--model "$MODEL"} ${EFFORT:+--effort "$EFFORT"} <<< "$PROMPT"
   ```

   On a non-zero exit, act per the Exit codes table of the skill `codex-triage`.

3. Validate every finding against the cited code and its consumers. Apply only
   valid findings. Push back with file:line evidence when a claim is wrong.
   Follow the shared skill's ownership contract for fixes, missing decisions and evidence.

4. Iterate within the authorized budget. At the cap, return outstanding findings and
   continue safe repairs; a required review follows "At the cap" in required-review.md.

## Required review

Read `${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/required-review.md`
for `--required`. It owns the claim/dispatch/record/check sequence and recovery.
