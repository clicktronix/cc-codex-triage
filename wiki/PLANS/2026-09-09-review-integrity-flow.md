# Review integrity and continuous flow

Delivery: [PR #7](https://github.com/clicktronix/cc-codex-triage/pull/7), branch
`fix/review-integrity-flow`. This extends the completed 0.11 simplification plan.

The owner keeps implementation, tasks and delivery. The bridge returns attributable
review evidence, preserves conversations and supports authorized bounded calls.

## Implemented in the PR

- [x] Bind required approval to the actual dispatch and revoke it on a later call.
- [x] Preserve explicit controls on resume and clean up reviewer descendants.
- [x] Add source-backed research, optional repository context and agent-owned maintenance.
- [x] Verify those changes with offline product routes and Linux/macOS CI at `8354134`.

## Review follow-up

- [x] Align reset/cap policy and runtime recovery messages without stopping safe work.
- [x] Diagnose an unusable Python runtime before modifying thread state.
- [x] Distinguish incomplete receipts from mismatched dispatch identities.
- [x] Clarify CLI compatibility, expose retained archives and document 0.12.0.
- [x] Reproduce regressions before fixes, then run `bash tests/run.sh` and review the diff.

Keep agent access to debate/status/list and owned idle advisory reset. No additional
budget ledger, version gate, automatic archive deletion or paid model evaluation.
Existing tests use offline CLIs; they do not establish real model adherence or the
minimum compatible Codex version. Follow-up changes belong to the same PR #7.

Local verification: manifest 126/0, driver 270/0, required 32/0 and product 15/15.
New runtime/archive regressions failed on the pre-fix code; the mismatched-receipt
control already rejected approval. Final required-contract rerun passed 32/0.
Hosted CI for the follow-up is tracked on PR #7 separately from these local results.

## Recovery review follow-up

- [x] Make invalid-claim recovery actionable without treating corruption as budget renewal.
- [x] Diagnose standalone Python failures at the existing context lookup.
- [x] Exercise intact-budget recovery and standalone maintenance failures; rerun the full suite.
