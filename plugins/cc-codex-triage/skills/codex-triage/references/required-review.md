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
   `CONTRACT_EXISTS` names the thread that already reviews this base and spec: the cap belongs
   to that contract, so continue or renew there. A base equal to the candidate is refused,
   since the range holds nothing to review.

   After integrating the target into an approved candidate (a merge whose first parent is that
   candidate, nothing else), add `--integration`: the round reviews the integration and does not
   count as an attempt. The exemption holds for a merge Git reproduces from its two parents; a
   resolved conflict or an edit added to the merge commit is reviewed as a normal round. A
   technical failure can retry the same merge. After blocking findings, use a normal round,
   including after a renewal.

2. The prompt begins with the header lines and ends with the footer lines. Generate both:

   ```bash
   HEADER="$("${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" header "$THREAD")"
   FOOTER="$("${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" footer "$THREAD")"
   ```

   The header is `REQUIRED_REVIEW`, `BASE_SHA:`, `CANDIDATE_SHA:` and `SPEC_PATH:` with the full
   values of the claimed candidate, once each. The footer is the verdict rule: the two verdicts
   `APPROVE` and `REQUEST_CHANGES`, findings located as `file:line`, a worktree left as found,
   and the bare final line. `dispatch.sh` checks both before calling Codex and exits 14 without
   dispatching when they differ; the claim stays live. `record` reads both again in the logged
   prompt, so a round dispatched without them ends as `STALE (prompt_scope_mismatch)`.

   Between them put the intent, the full base-to-candidate scope and the chosen lens. The
   footer is the round's only verdict instruction, on the first round and on every resumed one.

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
  attempt was returned. Begin again and ask for the findings with their locations. One attempt
  is returned per set of rounds: the next such reply is recorded as `REQUEST_CHANGES` and counts,
  and at the cap it ends the set like any blocking verdict.
- `STALE (dirty_worktree)`: the message lists the paths in the way, the first twenty and a
  count of the rest. The attempt counts. Remove or
  ignore a file the reviewer's command left behind before the next round.
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
"${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" renew "$THREAD" --by "$OWNER" ${ROUNDS:+--rounds "$ROUNDS"}
```

Pass `--rounds N` (1 up to the pinned cap) when the user authorized a number of rounds: two
authorized rounds on a cap of 5 run as attempts 4 and 5. Without it `renew` restarts the count
at the whole pinned cap, so name that number when you ask. `renew` is accepted at
`CAP_REACHED`, and for a used-up cap whose recorded approval no longer covers the candidate.
A `begin` refused at the cap leaves a recorded approval in place. Reuse a decision already
given. The cap belongs to the contract of base and spec, so a second thread name on them is
refused; resetting the thread loses the pinned contract, and `/thread-new` is for a
user-authorized change of base, spec or cap, or for the Recovery below.

## Candidate stability

The driver checks the actual clean HEAD/tree before and after the call and records a
completion receipt. These are endpoint checks, not proof of an immutable filesystem
throughout the call. The owner must keep the candidate stable while it is reviewed.
Claiming a new round supersedes the earlier approval. A rejected advisory call preserves it.

Keep the initial literal base SHA when the target branch advances: integrate the target
in the owning workflow, refresh affected evidence, and review the new candidate in this
thread.

## Recovery

A pending claim whose token was lost: read the `claim_token` line of `<thread>.candidate` in
the state directory (`/status` prints it), then `record` when its dispatch completed or
`abort` otherwise.

On `INVALID_CLAIM_STATE`:

1. Inspect the claim, loop, logs and receipts; a malformed claim does not necessarily
   invalidate the round count in `.review-loop`.
2. Restore an intact matching snapshot if available, writing only fields it records.
3. Otherwise archive and reset your owned idle thread with `/thread-new`, carry unresolved
   findings forward, and limit the next lifecycle to the confirmed remaining authorized
   attempts, counting completed or unresolved claims as used.
4. If no rounds remain or the count cannot be established, treat it as
   [At the cap](#at-the-cap). Corruption itself adds no rounds.
