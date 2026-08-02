# Gate internals — deferred refactors

Recorded 2026-08-02, from a four-angle cleanup review of `fix/review-loop-convergence`
(reuse / simplification / efficiency / altitude). Everything with a user-visible
failure mode was fixed on that branch; what is listed here is internal structure
that was **deliberately not** touched, because the branch was merge-ready and each
item needs a change the 690-check suite is pinned to.

Ordered by dependency: 1 unblocks 2.

## 1. `AMBIGUOUS` is a sentinel string on stdout

`scripts/last-verdict.sh` answers with a hex hash, nothing, or the literal
`AMBIGUOUS`, so one channel carries both payload and status. `hooks/stop-hook.sh`
then string-compares it in each gate branch.

**Fix:** use exit codes — 0 with a hash, 1 no verdict, 2 cannot be attributed.
`reviewed_fingerprint` propagates the status and callers write
`if ! rel="$(reviewed_fingerprint …)"`.

**Cost:** the parser, both gate branches, and the tests that assert the literal.

## 2. The two gate branches are near-parallel copies

`/autoreview` and `/autoplan` both run: read fields → validate counters → decide
release → resolve the released fingerprint → pre-0.9 carve-out → refuse if
unattributable → `rebaseline_cycle` → re-open the cycle if the tree moved →
cap check → block. Only the release predicate genuinely differs (verdict vs log
growth). They have already drifted: the AMBIGUOUS refusal emits its own
`emit_block` with an inline cap test in autoplan, while autoreview falls through
to the shared one.

**Fix:** one `run_gate()` taking (armed file, thread, current fp, dirt predicate,
release predicate, message set). The carve-out, refusal, re-block and cap then
exist once each and cannot drift.

**Cost:** a rewrite of the file's core against a suite pinned to the current
message strings. Do it after 1, which makes it mechanical.

## 3. The mkdir mutex exists twice

`hooks/stop-hook.sh` and `scripts/gate-state.sh` implement the same protocol
(mkdir claim, owner token, 30 s staleness, mtime-verified steal, ownership-checked
release), kept in sync by a comment. The hook's copy is justified — it must stay
dependency-free — but gate-state.sh is an ordinary `scripts/` file whose siblings
already source `lib.sh`.

Evidence that copies rot: a BSD-first `stat` probe had to be fixed separately in
three files on this branch.

**Fix:** the protocol moves to `lib.sh`; `gate-state.sh` sources it; the hook
keeps its copy with a pointer. The test seam moves with it.

## 4. Five test suites, five copies of `ok`/`bad`

Two lines each, so the copies are cheap; what drifts is the convention —
`manifest-lint.sh` silently drops the per-check message the others print.

**Fix:** `tests/lib.sh` with `ok`/`bad`/`summary`, sourced by all five.

## Known limitations (documented rather than fixed)

- **Gitignored files are outside every fingerprint**, deliberately: a gate
  firing on `.env` or build output would be unusable.
- **The acquisition-token guard has no test.** `armed_lock` must not count a
  lock as acquired when the owner-token write fails (a full or read-only state
  dir); the branch is reasoned about but not reproduced by any fixture, so it
  is stated here rather than claimed as covered.

## Status

All four refactors above were implemented on 2026-08-02, along with the log
rotation limitation this document originally listed (the driver now counts
rotations in `<thread>.log-gen`, and a changed count makes the gate parse the
whole current log — safe, because rotation precedes the append). Kept as the
record of why each was done.
