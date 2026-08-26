---
description: Review code with a persistent Codex thread. Use --required only when an owning workflow needs machine-checked approval for one exact clean candidate.
argument-hint: '[--required --base <ref> --spec <path>] [--lens <name>] [--thread <name>] [--once] [--cap N] [--background] <intent or focus>'
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh *)
---

# /review

Send the intent and scope, not copied file contents. Codex can inspect the
repository and run tests itself.

## Options

- `--thread <name>`: explicit thread. Otherwise run
  `${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh review`.
- `--lens correctness|security|performance|architecture|ux|quick`: default
  `correctness`. Read the matching short prompt from
  `../skills/codex-triage/references/review-lenses.md` on the initial round.
- `--once`: one advisory pass. Without it, address validated blocking findings
  and resume until `APPROVE` or `--cap` (default 5).
- `--background`: one advisory pass through `dispatch.sh`; never gate-eligible.
- `--required --base <ref> --spec <path>`: one foreground delivery-gate round.
  It cannot combine with `--once` or `--background`.

Use one task per thread. If an existing thread is clearly about another task,
choose a new explicit name instead of paying to resume unrelated history.

## Advisory review

1. Ensure the thread is not reserved by a required review:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" advisory-check "$THREAD"
   ```

2. On the first round, send the chosen lens. On later rounds say what changed
   and ask Codex to re-check earlier findings before looking for new ones.
   When evaluating a pasted third-party review, run one pass and ask Codex to
   classify each claim as valid, borderline, invalid, or outdated; do not ask
   it to implement the findings.

3. Dispatch in the foreground:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" <<< "$PROMPT"
   ```

   For `--background`, run this call as a Claude-managed background task. Handle
   long-dispatch handoff as defined by skill `codex-triage`; do not add another
   detach layer.

4. Validate every finding against the cited code and its consumers. Apply only
   valid findings. Push back with file:line evidence when a claim is wrong.
   Stop and ask the user when the decision is architectural or the evidence is
   unavailable.

5. Iterate only while blocking findings are converging. Stop at the cap or
   after two rounds of entirely new problem classes; review is then discovering
   the design rather than validating it.

## Required review

A required round only approves the clean HEAD/tree captured before dispatch.
The first round pins base, spec, and cap until `/thread-new` resets the thread.

1. Claim the round before the paid dispatch:

   ```bash
   BEGIN_RESULT=$("${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" begin "$THREAD" \
     --base "$BASE" --spec "$SPEC_PATH" --cap "$CAP")
   CLAIM_TOKEN="${BEGIN_RESULT##* claim=}"
   CLAIM_TOKEN="${CLAIM_TOKEN%% *}"
   ```

   Any failure stops the workflow. A dirty candidate is not downgraded to an
   advisory review.

2. The prompt must begin with these four lines, once each, with values read
   from the candidate record:

   ```text
   REQUIRED_REVIEW
   BASE_SHA: <canonical base SHA>
   CANDIDATE_SHA: <candidate HEAD>
   SPEC_PATH: <repo-relative spec path>
   ```

   Then include the intent, full base-to-candidate scope, chosen lens, and:

   ```text
   End your message with the verdict ALONE on its own final line — exactly APPROVE or REQUEST_CHANGES. Do not return COMMENT.
   ```

   Repeat the exact-verdict instruction on every resumed round.

3. Dispatch with mutation detection enabled:

   ```bash
   CC_CODEX_TRIAGE_STRICT=1 \
     "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" <<< "$PROMPT"
   ```

   If the dispatch failed before writing a completed record, release the claim
   with `review-state.sh abort`. During a long-dispatch handoff the claim stays
   live; wait for its watcher before recording.

4. Record the completed round and re-check approval:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" record "$THREAD" "$CLAIM_TOKEN"
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" check "$THREAD"
   ```

   Only the final command's exact marker authorizes the owning workflow:

   ```text
   CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<sha> tree=<sha> base_sha=<sha> spec_path=<path>
   ```

On `REQUEST_CHANGES`, return the validated findings to the owning workflow.
Do not edit, commit, or invent an approval inside this command. A refuted or
deferred finding may be explained on the same immutable candidate, but a fresh
round must still earn `APPROVE`. `CAP_REACHED` is a hard stop; only an explicit
`/thread-new` starts a new required lifecycle.
