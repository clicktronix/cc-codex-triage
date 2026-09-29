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

   After integrating the target into an approved candidate (a merge whose first parent is that
   candidate, nothing else), add `--integration`: the round reviews the integration and does not
   spend an attempt. Anything else is a normal round.

2. The prompt must begin with the four header lines, once each. Generate them; do not type them:

   ```bash
   HEADER="$("${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" header "$THREAD")"
   ```

   They are `REQUIRED_REVIEW`, `BASE_SHA:`, `CANDIDATE_SHA:` and `SPEC_PATH:` with the full values
   of the claimed candidate. `dispatch.sh` checks them before calling Codex and exits 14, having
   paid for nothing, when they differ; the claim stays live.

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
   For `INVALID_CLAIM_STATE`, follow [state recovery](../../../commands/thread-new.md#recovery).
   `STALE (dispatch_incomplete)` means the completion receipt is absent: inspect the
   dispatch error, including any strict mutation warning. It does not by itself mean
   the candidate changed. Reconcile the failure and retry only within the review budget.

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

`NO_FINDINGS` means Codex answered `REQUEST_CHANGES` without a single `file:line` finding; the
attempt was returned. Begin again and ask for the findings with their locations.

On `REQUEST_CHANGES`, return the validated findings to the owning workflow.
Do not edit, commit, or invent an approval inside this command. A refuted finding or a user-authorized
waiver may be explained on the same candidate, but a fresh round must earn `APPROVE`.
Tracking an issue does not resolve a defect. The owner decides whether independent future
work belongs elsewhere. At the cap, return terminal review state; the owner continues safe repairs
and reports the missing approval once. Another review budget needs user authorization; once given,
renew it on the same thread, which keeps base, spec and the Codex conversation and records who
authorized it:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" renew "$THREAD" --by "<who>"
```

Reuse a decision already given. Never reset or rename a thread merely to seek a favourable verdict.
The thread's model and effort are fixed by its first dispatch that names them; a later explicit
change is allowed and printed.

The driver checks the actual clean HEAD/tree before and after the call and records a
completion receipt. These are endpoint checks, not proof of an immutable filesystem
throughout the call. The owner must keep the candidate stable while it is reviewed.
A later reply or failed dispatch revokes earlier delivery permission.

Keep the initial literal base SHA when the target branch advances: integrate the target
in the owning workflow, refresh affected evidence, and review the new candidate in this
thread. An intentional change to base/spec/cap is a new contract, not an implicit reset.
