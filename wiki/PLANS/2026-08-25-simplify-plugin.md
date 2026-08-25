# Simplify cc-codex-triage

Recorded 2026-08-25 for PR #6. The change expands the newline fix into a
deliberate simplification pass. The product keeps persistent named Codex
threads and exact-candidate required review; optional state machines and live
compatibility layers are removed rather than translated.

## Invariants

- A required approval names the exact candidate the reviewer actually read.
- One verdict parser owns verdict recognition; strict and informational use are
  explicit modes of that parser.
- Model-invoked entry points receive only the executable permissions they need.
- Existing user state is not silently rewritten. This release is a breaking
  reset of legacy thread and gate state.
- Tests exercise the product route. Historical model samples are evidence, not
  an always-green runtime gate.

## Work

- [x] Bind resumable sessions to one worktree and reject cross-worktree reuse.
- [x] Route both strict and informational verdict reads through one parser.
- [x] Remove the findings ledger, disposition commands and `--continue` state.
- [x] Remove `/autoplan`, `/autoreview`, the Stop hook and their gate runtime.
- [x] Remove `/cleanup` and permanent pre-0.5/pre-0.9 migration code.
- [x] Scope command and model-invoked skill Bash permissions to plugin scripts.
- [x] Collapse the overlapping second-opinion trigger into `codex-triage` and
      trim the skill and lens reference to behavior the model needs.
- [x] Reclassify scenario files as historical evidence and remove stale claims.
- [x] Update manifests, READMEs, changelog and tests to the smaller surface.

## Verification

- [x] Product-route regression for reply framing through the production verdict
  parser.
- [x] Product-route regression that rejects cross-worktree resume.
- [x] Focused driver, required-review and manifest suites.
- [x] Full repository suite, `bash -n`, `git diff --check`, and residue searches for
  removed commands, hooks, migrations and state files.

Done when the retained named-thread and required-review flows are green, the
deleted features have no registrations or runtime residue, and PR #6 describes
the breaking simplification explicitly.
