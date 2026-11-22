# Required review

Contents: [Steps](#steps) · [Outcomes](#outcomes) · [At the cap](#at-the-cap) ·
[Candidate stability](#candidate-stability) · [Recovery](#recovery)

A required round only approves the clean HEAD/tree captured before dispatch.
The first round pins base, spec, and cap for the life of the thread; `renew` keeps them,
and only `/thread-new` starts a new contract.

## Steps

1. Claim the round before the dispatch:

   ```bash
   BEGIN_RESULT=$("${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" begin "$THREAD" \
     --base "$BASE" --spec "$SPEC_PATH" ${CAP:+--cap "$CAP"}) || exit $?
   CLAIM_TOKEN="${BEGIN_RESULT##* claim=}"
   CLAIM_TOKEN="${CLAIM_TOKEN%% *}"
   ```

   Omit `--cap` to use 7 on a new thread or its pinned cap on resume (1–7).
   If the first claim was interrupted, repeat `begin` for the same candidate to finish it.
   A refusal blocks this review attempt and delivery, not unrelated safe work.
   Preserve WIP; let the owner prepare a clean candidate instead of downgrading the gate.

   After integrating the target into an approved candidate (a merge whose first parent is that
   candidate, nothing else), add `--integration`: the round reviews the integration and does not
   count as an attempt. A technical failure can retry the same merge. After blocking
   findings, use a normal round, including after a renewal.

2. The prompt must begin with the four header lines, once each. Generate them; do not type them:

   ```bash
   HEADER="$("${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" header "$THREAD")"
   ```

   They are `REQUIRED_REVIEW`, `BASE_SHA:`, `CANDIDATE_SHA:` and `SPEC_PATH:` with the full values
   of the claimed candidate. `dispatch.sh` checks them before calling Codex and exits 14 without
   dispatching when they differ; the claim stays live.

   Then include the intent, full base-to-candidate scope, chosen lens, and:

   ```text
   End your message with the verdict ALONE on its own final line — exactly APPROVE or REQUEST_CHANGES.
   ```

   Required review accepts only `APPROVE` or `REQUEST_CHANGES`: findings the lens would
   label `COMMENT` go in the body, and the verdict is `APPROVE` when no blocking finding
   remains. Repeat the instruction on every resumed round.

3. Dispatch with mutation detection enabled:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" --strict <<< "$PROMPT"
   ```

   Append `--model` / `--effort` only when supplied.

   If the dispatch failed before writing a completed record, release the claim:

   ```bash
   ABORT_REASON=dispatch-failure  # or timeout / tool-failure
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" abort \
     "$THREAD" "$ABORT_REASON" "$CLAIM_TOKEN"
   ```

   If `abort` reports `ROUND_COMPLETED`, use `record` instead.
   For `INVALID_CLAIM_STATE`, follow [Recovery](#recovery).
   `STALE (dispatch_incomplete)`: no completion receipt. Read the dispatch error
   (including any strict mutation warning); the candidate may be unchanged. Retry only
   within the remaining rounds.

   During a long-dispatch handoff the claim stays live; wait for its watcher
   before recording.

4. Record immediately, before any edit or commit, including after `REQUEST_CHANGES`.
   On approval, check the exact candidate:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" record "$THREAD" "$CLAIM_TOKEN" || exit $?
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" check "$THREAD"
   ```

   The final command prints review evidence for the owner's candidate:

   ```text
   CC_CODEX_REQUIRED_REVIEW APPROVE thread=<thread> head=<sha> tree=<sha> base_sha=<sha> spec_path=<path>
   ```

   The owner applies its separate publication permissions.

## Outcomes

- `NO_FINDINGS`: Codex answered `REQUEST_CHANGES` without a single `file:line` finding; the
  attempt was returned. Begin again and ask for the findings with their locations.
- `NO_DECISION`: the final line was neither `APPROVE` nor `REQUEST_CHANGES` (`COMMENT`
  included). The attempt counts. Begin again with the exact-verdict instruction.
- `REQUEST_CHANGES`: return the validated findings to the owning workflow. This command
  edits nothing, commits nothing and invents no approval. Explain a refuted finding or
  a user-authorized waiver, but only a fresh round can return `APPROVE`. Tracking an issue
  does not resolve a defect.

## At the cap

`CAP_REACHED` stops further rounds and delivery. Return the terminal review state to the
owner, report the missing approval once, and continue safe repairs. Another set of rounds
needs user authorization; once given, renew on the same thread. That keeps base, spec and
the Codex conversation and records who authorized it:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" renew "$THREAD" --by "$OWNER"
```

`renew` restarts the round count at the pinned cap and is accepted only at `CAP_REACHED`.
Reuse a decision already given. Renaming or resetting the thread loses the pinned contract;
`/thread-new` is for a user-authorized change of base, spec or cap, or for the Recovery below.

## Candidate stability

The driver checks the actual clean HEAD/tree before and after the call and records a
completion receipt. These are endpoint checks, not proof of an immutable filesystem
throughout the call. The owner must keep the candidate stable while it is reviewed.
Claiming a new round supersedes the earlier approval. A rejected advisory call preserves it.

Keep the initial literal base SHA when the target branch advances: integrate the target
in the owning workflow, refresh affected evidence, and review the new candidate in this
thread.

## Recovery

On `INVALID_CLAIM_STATE`:

1. Inspect the claim, loop, logs and receipts; a malformed claim does not necessarily
   invalidate the round count in `.review-loop`.
2. Restore an intact matching snapshot if available, writing only fields it records.
3. Otherwise archive and reset your owned idle thread with `/thread-new`, carry unresolved
   findings forward, and limit the next lifecycle to the confirmed remaining authorized
   attempts, counting completed or unresolved claims as used.
4. If no rounds remain or the count cannot be established, treat it as
   [At the cap](#at-the-cap). Corruption itself adds no rounds.
