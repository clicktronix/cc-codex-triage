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

- [ ] Bind resumable sessions to one worktree and reject cross-worktree reuse.
- [ ] Route both strict and informational verdict reads through one parser.
- [ ] Remove the findings ledger, disposition commands and `--continue` state.
- [ ] Remove `/autoplan`, `/autoreview`, the Stop hook and their gate runtime.
- [ ] Remove `/cleanup` and permanent pre-0.5/pre-0.9 migration code.
- [ ] Scope command and model-invoked skill Bash permissions to plugin scripts.
- [ ] Collapse the overlapping second-opinion trigger into `codex-triage` and
      trim the skill and lens reference to behavior the model needs.
- [ ] Reclassify scenario files as historical evidence and remove stale claims.
- [ ] Update manifests, READMEs, changelog and tests to the smaller surface.

## Verification

- Product-route regression for reply framing through the production verdict
  parser.
- Product-route regression that rejects cross-worktree resume.
- Focused driver, required-review and manifest suites.
- Full repository suite, `bash -n`, `git diff --check`, and residue searches for
  removed commands, hooks, migrations and state files.

Done when the retained named-thread and required-review flows are green, the
deleted features have no registrations or runtime residue, and PR #6 describes
the breaking simplification explicitly.
