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

   A refusal blocks this review attempt and delivery, not unrelated safe work.
   Preserve WIP; let the owner prepare a clean candidate instead of downgrading the gate.

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
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" --strict <<< "$PROMPT"
   ```

   Append `--model` / `--effort` only when explicitly supplied.

   If the dispatch failed before writing a completed record, release the claim:

   ```bash
   ABORT_REASON=dispatch-failure  # or timeout / tool-failure
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" abort \
     "$THREAD" "$ABORT_REASON" "$CLAIM_TOKEN"
   ```

   If `abort` reports `ROUND_COMPLETED`, use `record` instead.

   During a long-dispatch handoff the claim stays live; wait for its watcher
   before recording.

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
Do not edit, commit, or invent an approval inside this command. A refuted finding or a user-authorized
waiver may be explained on the same candidate, but a fresh round must earn `APPROVE`.
Tracking an issue does not resolve a defect. The owner decides whether independent future
work belongs elsewhere. At the cap, return terminal review state; the owner continues safe repairs
and reports the missing approval once. Never reset merely to seek a favourable verdict.

The driver checks the actual clean HEAD/tree before and after the call and records a
completion receipt. These are endpoint checks, not proof of an immutable filesystem
throughout the call. The owner must keep the candidate stable while it is reviewed.
A later reply or failed dispatch revokes earlier delivery permission.

Keep the initial literal base SHA when the target branch advances: integrate the target
in the owning workflow, refresh affected evidence, and review the new candidate in this
thread. An intentional change to base/spec/cap is a new contract, not an implicit reset.
