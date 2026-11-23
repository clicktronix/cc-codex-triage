# Required review: gaps found in the field

Goal: a required review stops losing approvals and paid rounds, and the round limit stops being
avoidable by the routes seen in real thread logs (132 required rounds on 29 threads). An advisory
review gets a truthful instruction about its limit, and the threads pane stops accumulating old
review rows.

## Acceptance criteria

1. A `begin` refused at the cap writes nothing over a recorded approval: `check` still prints the
   marker for the approved candidate, and `--integration` still finds it. `renew` is accepted at
   `CAP_REACHED`, and for a used-up cap that still reads `APPROVED` once that approval no longer
   covers the candidate; it is refused while the approval covers it.
2. `renew <thread> --by <who> [--rounds N]` starts a set of N rounds, N from 1 to the pinned cap;
   without the flag the set is the whole cap. The cap stays pinned and `.review-loop` keeps its
   version 1 field set.
3. One required contract exists per base SHA and spec path in a state directory. The spec path
   is compared and stored as Git tracks it, so `docs/./spec.md` and `docs/spec.md` are one
   contract, also against state an earlier version saved under another spelling; a thread saved
   that way resumes and keeps its spelling. `begin` on a second thread answers `CONTRACT_EXISTS` (exit 10), names the holder
   and leaves no state. Two first claims that race do not both succeed, and a first claim
   interrupted before its check is checked when it is repeated. A reset of the holder frees the
   contract.
4. A `REQUEST_CHANGES` reply without a located finding returns its attempt once per set of rounds;
   the next one counts: it is recorded as `REQUEST_CHANGES` with reason `unlocated_findings`, or
   at the cap as `CAP_REACHED` with a refusal that says the reply located nothing. An integration
   round reserves no attempt: its first such reply is free, its second is `REQUEST_CHANGES`, and
   neither spends the attempt a normal round may have returned. A location is `<path>:<line>`
   where `<path>` is a file tracked in the candidate or in its base, or a file outside those
   trees that exists, written absolute or from the repository root with `../` (a finding in a
   consumer repository). The reply is searched for the tracked paths themselves, so a code span,
   brackets, quotes, a leading `./`, an absolute spelling and composed or decomposed marks all
   cite the same file. A directory, a path to nothing, `localhost:3000`, `node:20`, `sha256:1`
   and `step:2` name no file.
5. `footer <thread>` prints the closing lines of a required prompt. While a claim is pending,
   `preflight` (and so `dispatch.sh`) exits 14 without dispatching unless the prompt ends with
   exactly those lines, and `record` refuses a round whose logged prompt does not, as it does for
   the header (`STALE`, `prompt_scope_mismatch`). `verdict.sh` ignores trailing spaces, tabs and CR on reply lines and
   still rejects a verdict line that carries anything else.
6. `STALE (dirty_worktree)` lists the paths in the way, twenty and a count of the rest. The footer asks the reviewer to leave the
   worktree as found. The sandbox of a required round is unchanged.
7. `--integration` is accepted only for a merge whose tree equals the one
   `git merge-tree --write-tree` computes from its two parents. A resolved conflict, an edit added
   to the merge commit, or a Git that cannot recompute the merge gets `INTEGRATION_REFUSED`.
8. `--base` resolving to the candidate HEAD is refused with exit 1 and leaves no state.
9. The `PENDING` refusal of `begin` names the file that holds the claim token, and the Recovery
   section says how to finish a claim whose token was lost.
10. `commands/review.md` says that an advisory review stores no round count, how to recount its
    own prompts in the thread log, and to report an unknown count when the log cannot tell. No new state is kept for advisory reviews.
11. The pane lists the five required-review states written last, by file time, a `+N older` line
    for the rest, and an approval with the short SHA of its commit. A long thread name is cut
    before the state is.

The usage line stays one line and keeps `--integration`, `check <thread>` and
`renew <thread> --by <who>`. The approval marker is unchanged.

## Milestones

1. [x] **Gate fixes that need no owner decision (1, 4, 5, 7, 8, 9).** First, because the later
   changes edit the same `review-state.sh`. Each has a test in
   `tests/review-contract-regression.sh` that failed on the previous scripts.
2. [x] **Pane (11).** Separate, because it is the TypeScript mod with its own test runner.
3. [x] **Owner decisions (2, 3, 6, 10).** After 1: sized renewals and the single contract build
   on the reworked `begin` and `renew`. Decided: a sized renewal comes back as an optional flag,
   the cap binds to the contract, the reviewer keeps a writable sandbox, advisory reviews keep
   no state.
4. [x] **Documents and the caller contract.** After the code, so they describe what runs.
5. [ ] **Gate and review.** `bash tests/run.sh` on macOS and on Ubuntu in CI, then a required
   review of this branch through the changed scripts.

## Not in scope

- Recognizing a path by its shape. It was tried and dropped: three review rounds each found a
  spelling it misread. A location is now a file the reviewed trees track or the disk holds; of 72
  real `REQUEST_CHANGES` replies whose trees still exist, all 72 cite one, nine of them only in
  a sibling repository.
- A header or footer check inside the driver. Required rounds are dispatched through
  `dispatch.sh`, whose preflight runs before the paid call; a round that reached the driver
  another way is refused by `record`.
- A read-only sandbox for required rounds. Considered and declined by the owner: a reviewer's
  leftover file cost at most one round in 132.
- Carrying a used-up cap across a reset. `/thread-new` stays the owner-authorized way to start a
  new contract; its archive records the old one.
- Enforcement of the advisory limit.
