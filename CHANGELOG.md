# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Breaking
- Thread state is now worktree-local. Legacy `.claude/codex-threads` and
  common-Git state are not migrated; start new threads after upgrading. This
  prevents a resumed Codex session from reviewing the checkout where it was
  created while its result is attributed to another worktree.
- Removed `/autoplan`, `/autoreview`, the Stop hook, `/cleanup`, the findings
  ledger, `--continue`, the three finding-disposition commands, and the
  overlapping `codex-second-opinion` skill. Required review remains the only
  delivery gate.
- Removed the unused review-output schema, dead `DIVERGED` machine state, and
  manually duplicated translated READMEs.
- Removed the untyped `CC_CODEX_FLAGS` and `CC_CODEX_TRIAGE_STRICT` environment
  wrappers. Commands now use the driver's explicit `--read-only` and `--strict`
  flags, which survive command permission matching.

### Changed
- One strict `verdict.sh` owns delivery parsing. `/status` reports recorded
  required-review state instead of inferring approval-like text from old log
  prose.
- Worktree-local state is unconditional; an environment override can no longer
  reconnect two checkouts. Required review has one claimed `record` route, and
  its complete `begin -> dispatch -> record -> check` path is covered end to
  end.
- Short `/ask`, `/reply`, and `/thread` calls use the foreground driver;
  detached handoff is reserved for `/review`, `/plan`, and `/debate`.
- `/thread-new` is reset-only. It never combines state deletion with an
  optional paid dispatch.
- Required approval is bound to clean HEAD and tree. The former content
  fingerprint duplicated the same identity for a clean candidate and was
  removed with the optional gate subsystem.
- Command Bash permissions are scoped to bundled plugin executables instead of
  pre-approving arbitrary shell commands.
- Driver and required-review state share one recoverable directory-lock
  implementation instead of maintaining two copies of the same concurrency
  protocol.
- The primary skill and lens reference now contain only routing and behavioral
  rules needed by the current request.

### Fixed
- **A reply without a trailing newline no longer swallows the log separator.**
  The driver logged replies with `sed 's/^/  /'`, and BSD sed leaves an
  unterminated final line unterminated, so `---` landed on it. When that line
  was the verdict the log ended `  APPROVE---`, which the required-review
  recorder — comparing the line to `APPROVE` exactly — read as no verdict at
  all. Observed on a real pull request: Codex approved and no machine could
  attribute the approval, so the gate reported `CAP_REACHED` on a candidate its
  reviewer had passed. The driver now indents with `awk`, whose `print` always
  terminates the line and adds nothing when the input already did.

## [0.10.0] - 2026-08-12

### Added
- **Required review is an exact-candidate delivery gate.** Model-invocable
  `/review --required` claims one foreground round at a time and binds its
  result to the clean candidate HEAD, tree, content fingerprint, canonical
  base, and tracked spec. Only the self-verified machine marker is approval;
  timeout, background work, `REQUEST_CHANGES`, cap, divergence, stale scope,
  or candidate movement fails closed. Shared thread/review state survives
  disposable worktree removal, while gate state remains worktree-owned.
  Per-attempt claim tokens prevent another worktree from accidentally consuming
  a round; failed/UUID-less calls still consume the explicit cap, and cleanup
  protects a coherent pre-dispatch claim until its bounded TTL expires.

- **`/status` reports required-gate machine state.** Per thread it prints
  `status` / `gate_eligible` / `verdict`, whether a pre-dispatch claim is live
  or expired, and a `CAP_REACHED` / `DIVERGED` hard stop with its recovery
  step — states that previously existed only on disk. It also warns when the
  informational verdict column reads `APPROVE` while the required gate refused
  that round: the two parsers differ on purpose, and only one of them is the
  gate. The view stays read-only and never re-decides coverage; it names
  `review-state.sh check` as the authority instead.

### Fixed
- **`STALE` now records which failure it was.** One status covered a dirty
  worktree, a moved head or tree, a changed fingerprint, a reply that could not
  be attributed to this dispatch, a round counter that did not advance, and a
  prompt whose scope block did not match — all under one string. Those need
  opposite recoveries: re-cutting the candidate is right when it moved and
  destructive when the reply simply was not attributable. The cause is recorded
  and `/status` prints it.
- **A required round can no longer be lost to prompt order or verdict
  decoration.** `/review` stated "prepend" for both the machine scope block and
  a resume's follow-up header, while `record` accepts the scope only as the
  first four prompt lines — a correct-looking round landed `STALE` and burned a
  paid attempt. The block is now pinned as first with nothing before it, and
  every required round, resume included, restates the one output rule the
  required parser enforces, naming the two tokens required mode accepts and why
  `COMMENT` is not one of them. The exactly-once rule `record` also enforces is
  stated, so quoting `SPEC_PATH:` later in a prompt no longer lands `STALE`
  unexplained. `--cap` is documented as counting `begin` attempts including the
  first, and `/thread-new` documents that it clears the required-review state,
  which is the only exit from a hard stop.
- **Required-review state now fails closed across its full lifecycle.** Strict
  decimal parsing covers the driver counter, loop metadata, and candidate
  offsets without Bash octal fallthrough; completed rounds cannot be aborted or
  overwritten by a stale hard-stop claim, and base/spec/cap stay pinned until an
  explicit reset so changing arguments cannot restart the paid-round budget.
  Thread reset is one leased driver operation, cleanup serializes with candidate
  publication, read-only status paths no longer create caches, and legacy
  migration is recorded per source worktree so retained compatibility files may
  safely diverge afterwards.
- **Approval publication and cleanup rails are generation-safe.** A partial
  approval rename cannot combine a new status with an older candidate, cleanup
  aborts if any worktree gate cannot be discovered, and a repository-common
  registry serializes gate migration/publication with discovery, final rail
  checks, and archive moves. Armed-lock owner tokens use atomic noclobber
  publication, so a resumed pre-token loser cannot overwrite or remove the
  replacement generation.
- **The plan scope is followed at the third call site too.** `/autoplan on`
  asked `gate-fingerprint.sh --plan-paths` for the scope but, unlike the hook
  and `/status`, kept no fallback for an empty answer — which leaves
  `git status --` with no pathspec at all, i.e. the whole repository, and armed
  a paid plan dispatch on code-only changes.
- **An unfingerprintable worktree is no longer armed.** Both arming commands
  wrote whatever `gate-fingerprint.sh` printed into `fp_at_arming`, and an
  empty value makes the hook read a brand-new gate as a pre-0.9 one and fall
  back to 0.8 dirty-tree semantics — silently, at arming time. They now refuse.
- **A disarm that did not happen is no longer reported as one.** `gate-state.sh
  remove` exits 2 having deleted nothing when the mutex is held; the `off`
  snippets ignored its status, so the gate kept blocking every turn while the
  user had been told it was off.
- **A scoped fingerprint no longer moves for out-of-scope work.** When a plan
  path lives inside a submodule, the recursion carries the pathspec down
  instead of hashing the submodule whole, and it is folded in on every run
  rather than only when the submodule reads as dirty — either alone let an edit
  that touched no plan document open a paid plan cycle.
- **Removing a submodule no longer disables both gates.** A submodule whose
  worktree directory is gone made the recursion's `cd` fail and aborted the
  whole fingerprint, degrading to the dirty-tree predicate until the removal was
  committed — the "commit makes the gate go quiet" failure 0.9 exists to remove.
- **A signal landing between the child's reap and its PID being cleared no
  longer breaks the abort path.** Under `set -e` the unguarded `kill` in
  `abort_dispatch` aborted the trap itself, so the signal exit status and the
  last-abort marker were both lost.

### Tests
- Required-review regressions cover exact scope/verdict parsing, fenced and
  non-final verdict rejection, malformed persisted decimals, claim/cap
  ownership and contract pinning, same-candidate re-review after a documented
  disposition, stale-lock contention, partial approval publication,
  cleanup/gate publication races (including late worktrees), fail-closed
  worktree discovery, read-only state resolution, and serialized legacy gate
  migration across worktrees.
- Four assertions could not fail and now can, each verified by mutation: the
  TERM/KILL escalation (the fixture announced itself only after installing its
  trap), `--plan` scope drift (both scopes were empty, so both sides were the
  empty-tree hash), the seeded-index ignore purge (the rule moved to
  `.git/info/exclude`, which is not part of the tree), and READY resurrection
  (the fixture read an env var the driver had stopped exporting).
- New coverage for the two submodule fixes above, and the python-isolator case
  reports SKIP instead of FAIL when `python3` is absent.

## [0.9.0] - 2026-08-01

Closes the gaps that stopped the review loop rather than loosened it, found by
auditing 37 real thread logs across stokli and marqa (187 replies): every
verdict and finding header extracted per round, the divergent threads read in
full.

### Fixed
- **A gate never releases a state nothing recorded.** A verdict is paired with
  the fingerprint stamped into its own log record; where no record and no
  usable sidecar can say what was dispatched, the gate now answers "unknown"
  and keeps blocking instead of falling back to the worktree at turn-end —
  which would stamp bytes approved that were written after the review. The
  plan gate takes the LATEST post-cut record instead of the verdict's, since it
  releases on log growth rather than on a verdict. A pre-0.9 armed file is
  exempt: it has no fingerprint model at all and keeps 0.8 semantics until its
  first release, as documented. Refusing costs a round, not a deadlock — the
  next dispatch stamps its own record and settles it.
- **Every writer of armed state is serialized.** The Stop hook's three writers
  (block counter, idle consumption, cycle rebaseline) plus TTL expiry take one
  per-file mkdir mutex, re-read inside it, and write nothing when they cannot
  get it. Arming and disarming go through new `scripts/gate-state.sh` rather
  than writing the file straight from a command snippet, so a turn-end hook can
  no longer overwrite a fresh arming or resurrect a gate just switched off.
  Locks carry an owner token: a holder that stalls past the staleness window
  and resumes cannot delete the replacement owner's lock.
- **Dirty submodules are visible even when git is configured to hide them.**
  The probe passes `--ignore-submodules=none`, overriding
  `submodule.<name>.ignore` — a setting that exists to keep `git status` quiet,
  which is exactly why a gate must not honour it — and `--no-optional-locks`,
  since it runs at every turn end.
- **A dispatch is no longer lost to the caller's timeout.** The Bash tool caps
  a foreground call at 600 s — its maximum, not a setting — and a branch review
  routinely runs longer. When the cap hit, the round vanished: the paid Codex
  run finished into nowhere, and since the driver logs only on success it left
  no trace anywhere. What hid it is that **bash defers a trap until the current
  foreground child finishes**, so a TERM arriving mid-dispatch did nothing at
  all. The three `codex exec` calls now run in the background with `wait`
  (which IS interruptible), so TERM kills the child, frees the lease and
  records `<thread>.last-abort` — a sidecar, never the log, since `/autoplan`
  releases on log growth. New `scripts/dispatch.sh`, which every dispatching
  command routes through, detaches the worker and then waits for it in the
  foreground bounded below the caller's ceiling (`CC_DISPATCH_WAIT`, default
  540 s): a short dispatch answers in-turn exactly as before, and only one that
  would previously have been KILLED behaves differently — it **exits 20 and
  hands off**, worker untouched, re-runnable through the watcher. Its stdout is
  byte-identical to the reply (`/review --json` pipes it into `jq`), status goes
  to stderr, and the driver's exit codes survive rather than collapsing, so a
  caller can still tell a resume failure from a mutation refusal. 20 and 21
  deliberately avoid the driver's range: reusing 3 would make a LIVE dispatch
  indistinguishable from a dead one. `--oneshot` cannot detach (no thread state
  to hand off) and keeps the old ceiling; a throwaway is cheap to repeat.

- **The gates no longer go quiet at the moment the next round is owed.**
  `/autoreview` and `/autoplan` decided "is there work?" from
  `git status --porcelain` and "is it approved?" from the last verdict in the
  thread log. Both answers were wrong, and both reproduce:
  - committing the fixes made the tree clean, so the gate allowed the turn to
    end with the thread's last verdict still `REQUEST_CHANGES`;
  - the first APPROVE stayed the last parsed verdict for the rest of the
    arming, releasing every later turn no matter how much new unreviewed code
    was written.

  Both gates now work in **cycles**. A cycle opens when the code differs from
  the last released state and closes on a verdict earned inside it; each
  release re-baselines the approved fingerprint, the verdict window and the
  round budget together. The fingerprint (new
  `scripts/gate-fingerprint.sh`, shared by the hook and both arming commands)
  is a hash of the **working-tree content** in scope — the worktree staged into
  a throwaway index, then `git write-tree`. Content, not git bookkeeping,
  because the gate needs both directions: a fix survives its own commit and
  keeps the gate engaged, while committing already-approved bytes changes
  nothing and costs no review round. Untracked files are covered by content, a
  plan document being untracked for its whole first life; `.gitignore` is
  honoured, so a gate never fires on `.env` or build output.

  Backwards compatible: an armed file with neither `fp_at_arming` nor
  `released_fp` is a pre-0.9 arming, and keeps the old dirty-tree behaviour
  until its first release — after which the hook records `released_fp` and it
  follows the cycle model. An upgrade therefore never changes a gate
  mid-cycle, and an old gate still picks up the fix rather than carrying the
  holes until someone re-arms.

- **A review verdict the gate can actually read.** The review
  `output_contract` asked for "Last line is the verdict" while the parsers
  required a line consisting of nothing but the verdict. Codex legitimately
  writes `## APPROVE`. In one production thread **not one of five replies
  matched**, on a branch that was in fact approved — so the gate could never
  release and spent its whole cap on approved work. The contract now says the
  verdict stands alone on its own final line, and says why. The parser is now
  one script (`scripts/last-verdict.sh`, shared by the hook and `/status`,
  which previously carried separate copies) that trims heading marks and
  emphasis from the line ends and then compares exactly — accepting
  `## APPROVE` and `**APPROVE**` while still refusing "not quite APPROVE".
  Measured across the 187 production replies: 178 parsed before, 180 now.

- **Non-blocking findings are carried, not restated.** In
  `review-feat-400-analytics-ui` the same four non-blocking items were
  re-listed in full across rounds 2–6, one through round 7. The verdict was
  never wrong — `REQUEST_CHANGES` was correctly reserved for blocking items —
  but a converging round read as a stalled one, and each restatement bought
  another round. Still-open non-blocking items now carry as one
  count-and-titles line.

- **`/ask` can target a thread.** It was pinned to a single repo-wide `ask`
  thread with no override, contradicting the one-task-one-thread rule stated in
  the same document. It now takes `--thread`, and only applies its read-only
  default on an initial dispatch — `codex exec resume` accepts no `-s`, so
  passing it on a resume set a flag Codex ignores.

- **The comparison table in `README.md`** claimed an open-ended round cap,
  false since `/review` and `/plan` gained `--cap` (default 5).

- **The skill's exit-code list** omitted 2 and 3; exit 3 (dispatch failed) is
  the most common real failure and had no documented meaning.

- **`tests/driver-regression.sh`** symlinked `command -v python3` — a pyenv
  shim — into a minimal PATH farm where the shim cannot resolve, so the suite
  failed 2 on the maintainer's own machine while the product path was fine.

### Added

- **A divergence criterion: when the review loop is the wrong tool.**
  `review-refactor-266-thread-execution-lease` ran 13 rounds over three days,
  never reached APPROVE, and repeated **not one finding** — each round produced
  2–5 new blocking classes. That task's plan thread had ended at round 6 on
  `REQUEST_CHANGES` the day before implementation started. The rule keys on
  repeat structure rather than round count, because a 9-round thread whose
  blocking findings decay 10 → 0 is converging and must not be interrupted.
  Ships with `tests/scenarios/codex-triage/review-divergence.json`, a
  production RED with no synthetic baseline, which says so.

- **Skill `codex-second-opinion`** — the one part of this plugin Claude may
  invoke itself. Every slash command is `disable-model-invocation`, so an agent
  wanting a third opinion mid-task had to read a 101-line command file to get
  one. This is a single bounded dispatch for a fork the repository cannot
  settle, an irreversible change, or two sources that contradict each other. It
  announces the cost before spending it, spends exactly one dispatch, and never
  targets a gate thread (`review-<branch>` or `plan-<branch>`). It ships with **no baseline**, and
  `tests/scenarios/README.md` records both that fact and the RED that would
  test it.

- **A release is bound to the verdict that earned it.** The driver captures the
  code state *before* invoking Codex and stamps it into that dispatch's log
  record (`fp=` / `fp-plan=`); the parser returns the fingerprint belonging to
  the record whose verdict was selected. Choosing the verdict from the log and
  the fingerprint from a mutable sidecar independently meant an APPROVE for
  state A followed by a successful but verdict-less dispatch B released B, which
  nothing had approved. Records written before the header carried these fields
  fall back to the sidecar, so existing threads keep working.

- **Gate releases are bound to the state the dispatch saw.** The driver records
  a fingerprint on every successful dispatch — whole-tree, plus a plan-scoped one
  for the armed plan thread — and each gate releases against that rather than the
  worktree at turn-end. A release that is already stale opens the next cycle
  immediately instead of letting the turn finish. Idle-verdict consumption
  advances only the verdict cut: it used to reset the round budget too, so
  reverting to the released state and reapplying the change bought a full cap
  again, repeatably.

- **Threads are findable, not just resumable.** `--topic "<text>"` on the driver
  records one line about what a thread holds, set when it is created and never
  overwritten (cleared by `--new`). New `scripts/thread-index.sh` lists every
  thread with its rounds, size, last activity, topic and a `[busy]` marker;
  `/thread-list` now prints it. It is a local read with no Codex dispatch, so
  the `codex-second-opinion` skill runs it to **reuse an existing thread rather
  than open a new one** — until now every listing surface was
  `disable-model-invocation`, so an agent told to reuse a feature's thread had
  no way to see which threads existed or what they held.

- **The one-feature-one-thread convention.** Thread defaults are per *command
  kind*, so a feature's context splits across three or four Codex sessions that
  each know a third of the story. Documented with its two real limits: the
  sandbox is fixed at session creation (verified against codex-cli 0.146), and
  a large thread is worth splitting rather than resumed indefinitely (production
  threads reach ~130 KB by round 9 — calibration, not a tested threshold).

### Note on versioning

No git tags exist in this repository, including for 0.7.0 and 0.8.0 — the
0.8.0 entry below was written before its own work finished (13 commits landed
after the release commit), so there is no commit that cleanly marks it.
Tagging from 0.9.0 onward.

## [0.8.0] - 2026-07-19

Closes six state-hygiene gaps surfaced by a 2026-07-19 audit of real
thread-state dirs across six production repos (marqa agent/platform/analyzer +
a container root, stokli frontend/backend). Plan:
`wiki/ARCHIVE/PLANS/2026-07-19-hygiene-0.8.md`.

### Fixed

- **`/cleanup --apply` archives under the driver's acquisition mutex.** The
  apply-time rail re-check had a TOCTOU window: a dispatch could acquire the
  thread's lease between the check and that unit's `mv`s. Each per-thread
  unit (flat targets and dormant sets alike) now takes the SAME
  `<thread>.active.lock` mkdir mutex the driver serializes lease grants
  through — rails re-checked inside the lock, held until the unit's moves
  finish, released ownership-checked; takeover mirrors the driver (live
  owner never stolen, dead owner reclaimed at once, ownerless > 60s
  reclaimed). A dispatch starting mid-archive is refused (exit 10) instead
  of racing. Regression-tested via a post-lock injection seam
  (`CC_CLEANUP_TEST_POST_LOCK_HOOK`).
- **`--background` now has a completion-delivery path.** New
  `scripts/detach-watch.sh <thread> <pid> [log-offset]`: run it as a
  Claude-managed background task after the `DETACHED` line — it waits on the
  worker PID (the one signal that fires on success AND on post-READY
  failure, which appends no `round=` header and so defeated log polling),
  then delivers the worker-owned `detach-output` reply (exit 0), the `last-error` +
  `detach-output` diagnostics (exit 1), or a still-running timeout notice
  (exit 3). The watcher's verdict comes from `<thread>.detach-status` — the
  worker's REAL exit code, published atomically by its EXIT trap — never
  from log growth (a strict-mutation exit 5 appends the exchange and still
  fails); a missing/mismatched record is reported as UNKNOWN (exit 4, treat
  as failure until verified), not assumed success. The child's stdout and
  stderr are split (`<thread>.detach-output` / `<thread>.detach-stderr`,
  both truncated per launch by the lease OWNER, boundary established right
  after lease acquisition) so a successful run's warnings — invalid saved
  .id discarded, ignored resume overrides, porcelain guard notes — are
  delivered by the watcher instead of being lost with the launcher's
  pre-lease tmpfile. Success reads the reply from `detach-output`, not a shared
  log delta, so a later foreground round on the same thread cannot be
  misattributed to the detached worker. The launcher measures
  `log-offset=<B>` BEFORE spawning the child for failure/UNKNOWN diagnostics.
  A concurrent exit-10 loser can no longer truncate or interleave the
  winner's sidecars. `/review`/`/plan` `--background` steps wire the
  watcher up explicitly.
- **Mutating utilities hard-fail outside a git repository (exit 7, driver
  parity).** `cleanup.sh` and `ledger.sh` previously fell back to the
  caller's cwd — archiving/writing state the driver could never have put
  there; read-only `status.sh` now no-ops with a message, and the mutating
  command snippets (`/autoreview`, `/autoplan`, `/thread-new`) guard their
  `cd "$(git ...)"` with `|| exit 7`.
- **A broken `ps` no longer reads as a dead child.** `proc_state()` probes
  `ps` against `$$` when the target lookup fails: self listable → target
  really is gone/zombie; self unlistable (process-restricted sandbox) →
  UNKNOWN, and the launcher trusts `kill -0` alone — previously every such
  environment misreported healthy detached children (observed as launcher
  failure storms under a restricted sandbox).
- **Armed gates now expire after 14 days.** Arming writes `armed_at=<epoch>`;
  the Stop hook runs a TTL pre-pass over BOTH armed files before any gate
  evaluates branch/dirt — each expired file is removed with a stderr note and
  evaluation continues to the surviving gates (a pre-pass, not an inline allow,
  so one gate's expiry can never suppress or orphan the other). Missing,
  malformed, or future `armed_at` (including every ≤0.7 armed file) skips the
  TTL — fail-open, nothing starts blocking on upgrade. `/status` shows a gate's
  age and warns past 14 days. Closes the audited incident class of month-old
  armed gates sitting on long-merged branches, waiting to re-fire the moment a
  branch name is reused.
- **Driver state is anchored to the RESOLVED repo root, or refused (exit 7).**
  Persistent modes derive the anchor as `git -C "${CLAUDE_PROJECT_DIR:-$PWD}"
  rev-parse --show-toplevel` — never the raw candidate: a candidate inside a
  repo subdirectory resolves UP to the root (driver and hook state can no
  longer split), and a candidate that is not a repo at all (unset var in a
  non-repo cwd, `CLAUDE_PROJECT_DIR` pointing at a non-repo or nonexistent
  path) exits 7 naming the candidate and the fixes (cd into a repo / fix the
  var / use `--oneshot`, which keeps its no-state exception). Closes the
  audited incident of a full thread-state dir stranded in a non-repo container
  directory the hook could never see.
- **`last-error.jsonl` now means the LAST error.** The moment a dispatch exits
  0, the thread's previous diag is removed — before UUID extraction, so a
  UUID-extraction failure (which writes a fresh diag even on exit 0) lands in
  a clean slot and is never erased by its own dispatch. Every failure-path
  diag write is capped to the last 64 KB of the stream. Closes the audited
  235 KB diag and the stale diags that survived threads whose reviews had long
  since reached APPROVE.

### Changed

- **`/reply`'s default thread now matches `/review`'s** — `review-<branch-slug>`
  (same `tr -c 'a-zA-Z0-9_.-' '-'` slug rule), falling back to a bare `review`
  thread when only that exists, with a one-line legacy warning; the
  `--require-existing` / exit-6 semantics are unchanged. Closes the audited
  incident of a bare `/reply` on a feature branch silently resuming a 77 KB
  June-old `review` thread instead of the branch's own.

### Added

- **Two new `/cleanup` detection classes.** (a) **Stale last-error diags** — a
  diag whose thread has no `.id` (orphan) or whose `.log` is newer (recovered)
  is archivable; a fresh diag is not flagged. (b) **Dormant threads** —
  `--older-than <days>` (integer ≥ 1) lists/archives whole thread file-sets
  (`id, log, log.1, rounds, findings.jsonl, scope, approved, last-error.jsonl,
  detach-output, detach-stderr, detach-status, active`) whose newest member
  is older than N days. Safety
  rails, in precedence order: a thread whose `.active` lease names a live PID
  is skipped unconditionally (a resume waiting inside `codex exec` writes
  nothing mtime could see — the lease is the only honest in-use signal; a
  dead-PID lease is itself stale and joins the set); threads named by an armed
  gate's `thread=` are excluded; on `--apply` each set's newest mtime is
  re-checked immediately before the move; generic `review`/`plan` stay
  list-only. Closes the two audited stale-state classes `/cleanup` was blind
  to. The lease itself is written by the driver: `<thread>.active` holds the
  dispatching PID for the whole dispatch, removal is ownership-checked.
- **Driver `--detach`** — re-execs the dispatch in its OWN session (`setsid`,
  or `python3 os.setsid()+execvp` where the binary is missing; plain `nohup`
  shields only SIGHUP, not the group-targeted kill that was actually observed)
  so it survives harness process-reaping. Readiness handshake: the child
  acquires its PID lease FIRST and only then reports ready, so a printed
  `DETACHED pid=<pid> output=<thread>.detach-output` guarantees `/cleanup`
  already sees the thread as in-use. New exit codes: 8 — no isolator on PATH,
  refused with zero state written; 9 — handshake timeout, spawn killed; 10 —
  thread busy: the dispatch lease could not be acquired (another dispatch
  holds `<thread>.active` with a live PID, a concurrent claim holds the
  acquisition mutex, or the lease is not a regular file). Lease acquisition
  runs under an ownership-safe mkdir mutex (`<thread>.active.lock` with an
  owner-PID token): live-owner locks are never stolen, dead-owner or
  ownerless-stale locks are reclaimed automatically. The
  child's streams are split per launch by the lease-owning child: stdout
  (the reply echo) to `<thread>.detach-output`, stderr (warnings/errors) to
  `<thread>.detach-stderr`, and its real exit status is published to
  `<thread>.detach-status`; the thread `.log` marker contract is
  untouched. `/review`/`/plan` `--background` now recommends `--detach` plus
  the bundled `detach-watch.sh` watcher run as a Claude-managed background
  task — it delivers the reply or the failure diagnostics (verdict from the
  published exit status, NOT from log growth) as a completion notification;
  the harness's `run_in_background` on the plain command stays documented as
  the fallback with its reaping caveat. Closes the audited incident class of background dispatches
  dying mid-flight when the harness reaped the process group.

### Documentation

- README (en/ru/es): same-thread dispatches are serialized by the lease/mutex
  (exit 10) — the old "two sessions can race the counters/log" claim is
  superseded; the one-session-per-repo guidance now names the real remaining
  surface (gate arming files, findings ledger, written outside the driver's
  lease).

## [0.7.0] - 2026-07-07

### Added

- **XML-block prompt contracts.** `review-lenses.md` is restructured into a
  reusable block library plus per-lens `<task>` blocks; commands assemble the
  lens from named blocks instead of one flat template. No user-facing flag —
  internal to how the prompt is built.
- **`--model <m>` / `--effort <e>`** on `/review` and `/plan` — forwarded to
  the driver, which applies them on the initial or `--oneshot` dispatch only;
  a resume keeps the thread's model/effort stable and WARNs if you pass them
  again (use `--new` to change them).
- **`--background`** on `/review` and `/plan` — launches the driver detached
  and returns the turn without waiting; implies a single pass, same as
  `--once`.
- **`--json`** on `/review` — opt-in structured output: Codex returns JSON per
  `schemas/review-output.schema.json` instead of Conventional Comments prose,
  rendered to a human view and auto-recorded in the findings ledger with a new
  **`confidence`** (0..1) field per finding. Works on an initial dispatch or on
  an existing thread (resume). Needs `codex` ≥ 0.142 (for `--output-schema`)
  and `jq`. The `/autoreview` gate stays text-mode — a `--json` reply cannot
  release it.

### Changed

- **RED-baseline provenance moved out of the skill body** into
  `skills/codex-triage/references/test-provenance.md`; SKILL.md keeps a
  one-line rule-strength label per rule. Behavioural rule text is unchanged —
  this removes dated maintainer records from always-loaded guidance (per
  Anthropic's skill-authoring best practices) and trims the body.

## [0.6.0] - 2026-06-21

Backlog from a usage audit of ~23 real review/plan threads across two repos,
validated against the source with a Codex `/plan` stress-test.

### Added

- **`/status`** — one-screen, read-only view of the plugin's state in a repo:
  current branch, dirty tree, armed `/autoreview` / `/autoplan` gates with
  **stale-branch**, **pre-0.5** and **missing-target-thread** warnings, last
  verdict per thread, gitignore status, and the Codex CLI version vs the
  required minimum. Folds together state that used to need hand-reading
  `.armed` / `.rounds` / `.log` + `git`.
- **`/cleanup`** — finds stale/pre-0.5 armed gates, orphan thread logs (a
  `.log` with no `.id`), and generic-name threads. Dry-run by default; `--apply`
  **archives** (never deletes) into a reversible `.archive-<timestamp>/`.
- **Plan lenses now emit a machine verdict** (`APPROVE | REQUEST_CHANGES |
  COMMENT`), the same token reviews use — so `/status` and tooling can read a
  plan's verdict instead of guessing from prose. (The `/autoplan` gate still
  releases on thread-log growth, not the verdict; verdict-gating the plan gate is
  a deferred follow-up.)
- **`CC_CODEX_PLAN_PATHS`** — configurable plan-doc locations for `/autoplan`
  (space-separated pathspecs; default `docs/plans docs/PLANS`).
- **Findings ledger** (`scripts/ledger.sh` + `<thread>.findings.jsonl`) — an
  event-sourced, machine-readable record of review findings (helper-allocated
  stable ids, folded to a current status). `/review` records findings as it
  validates them and renders the user summary from the ledger; **`/review
  --continue`** rebuilds the resume prompt from the still-open findings + the
  diff since a recorded APPROVE baseline instead of hand-narration. New
  **`/review-dispute`**, **`/review-accept`**, **`/review-defer`** dispose of a
  finding by id. The sidecars (`.findings.jsonl`, `.scope`, `.approved`) are
  reset on `--new` / `/thread-new` and archived with orphans by `/cleanup`.
  The ledger is **fail-closed**: a corrupt or partial JSONL is refused by both
  the readers (`open`/`list`/`get`) and the writers (`create`/`status`) through
  one shared validator — never rendered as silently-empty, never appended onto —
  and id allocation ignores malformed ids, so a finding can't be lost,
  re-numbered onto an existing one, or hidden by a bad line. `create` requires a
  `file:line` citation; the pinned `.scope` records the integration-branch
  merge-base (not the upstream one, which on a pushed branch is only the last
  push). (Ledger features need `jq`; without it the core review still works.)

### Changed

- **`/review` and `/plan` iterate to APPROVE by default** (dispatch → address
  blocking findings → re-review, until APPROVE or `--cap` rounds, default 5).
  `--once` does a single pass; `--oneshot` stays ephemeral. ~89% of real review
  threads were already multi-round, so the loop is now the default rather than a
  separate gated command. A pasted third-party review (Judge-mode) always runs a
  **single classification pass**, never a loop.
- **Default threads are branch-scoped** — `review-<branch>` / `plan-<branch>`
  (e.g. `review-main` on `main` — no main/master special-case, matching the
  hook's slug rule so a manual review and the gate share one thread); the bare
  `review`/`plan` names are only via an explicit `--thread`. Plus a reuse guard
  that warns when a thread already holds a different task.
- **Verdict is gated on blocking findings only** — `REQUEST_CHANGES` requires at
  least one `(blocking)` finding; nitpicks (test hygiene, naming) no longer hold
  the verdict.
- **Round numbers come from the driver header**, not hand-written prose — the
  commands stopped injecting "round N" (which drifted from the driver's
  `round=N`), and the **lens contract is sent only on the initial dispatch**
  (the thread already retains it on resume).
- **Untracked new files are explicitly pulled into review scope** (they are not
  in `git diff HEAD` and previously fell out of the review).

### Fixed

- Dropped a dead boilerplate line ("If you have a code-review skill loaded…")
  from the shared review contract.

### Notes

- One backlog item is deferred to a focused follow-up: **state-file locking**
  (the README's documented "one session per repo" limitation — the `.rounds` /
  `.log` / ledger writes are not yet locked across concurrent sessions). Tracked
  for a later release.

## [0.5.1] - 2026-06-14

### Changed

- **`/debate` round count raised: default `3`→`5`, max `5`→`15`.** The cap only ever bounded cost; the "advance or sharpen" rule already ends a debate early once a round adds no new evidence, so a higher ceiling lets a genuinely deep disagreement run longer without padding shallow ones. Cost note updated: for `--rounds 10`+, confirm with the user first.
- **`/debate` output is now a clean per-speaker transcript, and the anti-capitulation rules no longer leak into the prose.** A real debate (marqa, thread `debate-product-functional-additions`) showed Claude narrating the rulebook out loud — "Уступаю с называнием доказательства:", "Держу и заостряю:", "residual-решение, на котором не уступаю — SEQUENCING плацдарма" — plus untranslated jargon (wedge/moat/residual/sequencing). Added an **"argue, don't narrate the rules"** bullet to the skill's Debating-Codex section (the rules govern reasoning, not wording; write in the conversation's language, no rule-labels, no untranslated jargon — Codex's verbatim reply exempt) and an explicit **Presentation format** to the `/debate` command: each round rendered as framed, visually separated **Claude Code** / **Codex** (verbatim) blocks, closing with a single **Result** block (agreed / still open / what moved / recommendation). RED→GREEN documented in `tests/scenarios/codex-triage/debate-presentation.json`.

## [0.5.0] - 2026-06-12

Fixes from a full plugin audit (two parallel audit subagents — shell scripts and
structure-vs-spec — checked against current official plugin/hooks/skills docs,
every Important+ finding re-verified against the code before fixing; one
finding refuted in validation: `statusMessage` IS a documented hook field).

### Fixed

- **The self-verification gate was not satisfiable by the model alone.**
  `/review` and `/plan` are `disable-model-invocation`, but the Stop hook's
  block reason and `/autoreview`/`/autoplan` step 3 told Claude to "run
  /review" — a command it cannot invoke and whose steps it cannot see. The
  hook now derives the plugin root from its own location and points the block
  reason at the command FILE to read and follow
  (`<plugin>/commands/review.md`); arming steps reference
  `${CLAUDE_PLUGIN_ROOT}/commands/*.md` the same way; the skill documents the
  direct driver invocation (`scripts/codex-thread.sh`) and the absolute lens
  template path, so the model-facing route is complete without making the
  commands model-invocable (Codex dispatches stay user-pace, cost-bounded).
- **Stale APPROVE from a previous arming released a new `/autoreview` gate.**
  The verdict check wasn't tied to the arming moment, so re-arming on a branch
  whose log ended in an old APPROVE released instantly — new code never
  reviewed. Final mechanics (hardened across two rounds of Codex's own review
  of this changeset, thread `review-v0.5.0-audit`): `autoreview.armed`
  snapshots **`log_bytes_at_arming`** and the hook parses verdicts ONLY from
  log content appended after that offset. The offset is self-sufficient — a
  post-offset APPROVE proves a post-arming round — so no `.rounds`-based
  check remains anywhere in the hook: that counter is reset by `/thread-new`,
  letting a bare reset fake a run (and a post-reset run collide with a
  snapshot). For the same reason **`/autoplan` now releases on log-size
  change since arming** instead of a round-counter comparison (honest caveat,
  documented in the command: any dispatch to the plan thread grows the log,
  so strictly the gate guarantees a post-arming dispatch, not specifically a
  `/plan` run). A missing `log_bytes_at_arming` (pre-0.5 armed file) is
  treated as malformed state: fail open with a re-arm note — NOT a zero
  offset, which would rescan the whole log and re-open the stale-APPROVE hole
  on upgrade. Required numeric fields are read raw, so a present-but-EMPTY
  `log_bytes_at_arming=`/`cap=`/`blocks=` is also malformed (fail open), not
  a silent default that would bypass the same guard. The offset cut also
  replaced the old 400-line tail window, so a single long reply can no
  longer push its verdict out of the parser's scope. Re-arm after upgrading.
- **A verdict literal inside a logged PROMPT could fake the gate's APPROVE.**
  The verdict scanner grepped the whole log tail; PROMPT and REPLY bodies are
  indented identically, so a `/reply` quoting "earlier you said: APPROVE"
  released the gate. The scanner is now a section-aware parser that only reads
  verdicts between the driver's column-0 `REPLY:` and `---` markers (the log
  format contract is now documented in the driver).
- **Leading-zero counters (`blocks=08`) fail-closed the gate forever.** bash
  parses `08` as invalid octal in `[[ -ge ]]` and in the bump arithmetic, so
  the cap never compared and the counter never persisted — unlimited blocking,
  the exact inverse of the documented fail-open contract. `is_num` now rejects
  leading zeros; malformed counters fail open.
- **Unwritable state dir bypassed the cap into unlimited blocking.**
  `bump_blocks` ignored persist failures while the caller emitted the block
  unconditionally. A block is now emitted only when the incremented counter
  was actually persisted; otherwise the hook fails open with a stderr note.
- **Tab/CR in the armed lens value produced invalid block JSON.** The reason
  sanitizer only stripped quote/backslash/newline. It now maps ALL control
  characters to spaces, and lens values are validated against exact per-gate
  allowlists (see below).
- **Corrupted/CRLF `.rounds` killed the driver AFTER a successful paid
  dispatch** (arithmetic error under `set -e` before the reply was printed or
  logged). The counter is validated and garbage resets to 0 — including
  leading-zero values (`08`), which bash arithmetic parses as invalid octal;
  the first validation pass used `^[0-9]+$` and Codex's review caught that it
  re-admitted the exact octal trap fixed in the hook. Same fix for
  `CC_CODEX_TRIAGE_LOG_CAP_BYTES`.
- **`--new --require-existing` destroyed the thread it then refused to use**
  (`rm` ran before the check). The combination is now refused up front as
  mutually exclusive.
- **UUID extraction silently broke on whitespace in codex JSON output.** The
  awk used fixed substr offsets valid only for fully compact JSON while its
  regex pretended to tolerate spaces. Now a two-step match-then-strip with no
  offsets; a `"thread_id": "..."` (space after colon) persists correctly.
- **cwd drift split thread state.** State paths are repo-relative but the Bash
  tool's cwd persists across calls; dispatching from a subdirectory created a
  second `.claude/codex-threads/` the Stop hook never saw. Driver and hook now
  anchor to `CLAUDE_PROJECT_DIR`/git toplevel before touching state — and so
  do all model-facing bash snippets in the command files (arming, off/status,
  round-counter reads, `/reply` thread detection, `/thread-list`,
  `/thread-new`), which Codex's review flagged as the remaining unanchored
  ingress points of the same class.
- **The hook's lens check is now an exact allowlist per gate** (review and
  plan lens sets), not a character-class filter — a printable-but-unknown
  lens in a corrupted armed file falls back to the gate default instead of
  routing the model to an invalid `--lens` invocation.
- **Branch-to-thread slugs now map every character outside the driver's
  `[a-zA-Z0-9_.-]` alphabet to `-`**, not just `/` — git allows `+`, `#`,
  `@` etc. in branch names, and the old slug produced thread names the driver
  rejects, making the gate's requested route unsatisfiable until cap. One
  shared rule in the hook fallback and both arming snippets.
- **A mistyped flag (`--oneshto`) silently became a thread name** and burned a
  dispatch. Unknown `-*` arguments are now rejected.
- A transient `git status` failure (e.g. index.lock) no longer masquerades as
  a clean porcelain — the mutation guard skips the comparison (instead of
  false-positiving, fatal under `CC_CODEX_TRIAGE_STRICT=1`), and the strict
  exit 5 now happens AFTER the audit log append so the suspicious exchange is
  logged. Non-numeric `CC_CODEX_TRIAGE_LOG_CAP_BYTES` falls back to the
  default instead of disabling rotation. Detached HEAD (`branch=HEAD`) no
  longer matches an armed gate.
- Docs/manifest hygiene: root README caught up to 0.4.x (command list, repo
  layout, round-cap claim); codex CLI floor corrected to the verified 0.137.0;
  `/ask` steps reordered (compose prompt before dispatch); two scenario
  `tests_reference` anchors fixed; `/reply` default-thread routing synced
  between SKILL table and command; `keywords` moved to plugin.json (with
  `displayName` and `repository` added); LICENSE copied into the plugin dir;
  documented the CC_CODEX_FLAGS no-spaces-in-values limitation and the
  one-session-per-repo concurrency assumption.

### Added

- **"Validating inbound Codex findings" rule** in the `codex-triage` skill, and a VERIFY/EVALUATE step in `/review` before fixes are applied. A Codex review reply is now treated as claims to verify against the code (read the cited site *and its consumers*, check for a documented reason the current code stands, confirm the suggested fix doesn't regress, classify valid/borderline/invalid/outdated) before applying — invalid findings get rejected via `/reply` with file:line. Explicitly forbids applying a finding you believe is wrong just to release the `/autoreview` APPROVE gate (the round cap, not compliance, is the escape hatch). Encodes the verify-before-apply principle inline so it no longer depends on an external skill (`superpowers:receiving-code-review`) being installed. RED scenario `tests/scenarios/codex-triage/inbound-finding-validation.json` (did-not-reproduce on strong models with in-context evidence; kept as a brief, self-containing reminder — see the scenario for the honest verdict).
- **"The driver" section in the skill** — the direct `codex-thread.sh` invocation, exit codes, and command-file paths, so the model has an executable route when no command body is in context.
- **`tests/driver-regression.sh`** — 23-assertion driver suite against a stubbed `codex` CLI (usage errors, UUID persistence, corrupted-state survival incl. the octal trap, whitespace-tolerant extraction, oneshot tracelessness, cwd anchoring, failure diagnostics).
- Hook suite grown from 19 to 48 assertions; both halves of the fail-open contract are now asserted on every run (decision AND exit code), plus regressions for every gate bug above (stale-APPROVE offset cut, PROMPT spoof, octal counters, pre-0.5 armed files, present-but-empty required fields, bare-reset fake runs, lens allowlist fallback, branch-slug alphabet, read-only state dir, detached HEAD).

## [0.4.2] - 2026-06-11

### Changed

- **`/autoreview on` and `/autoplan on` now review/stress-test existing work immediately.** Previously arming only set the gate, so already-implemented changes sat unreviewed until the next turn-end and users ran `/review` by hand. Arming now checks the tree: if the branch is already dirty (code for autoreview, `docs/plans|PLANS` for autoplan) it runs the review/stress-test right away on the per-branch thread, then keeps gating future turns. Clean tree → no-op, gate armed for future changes. Removes the manual first `/review`.

## [0.4.1] - 2026-06-09

Fixes from a post-release code review (subagent reviewer, live-tested under
bash 3.2/5, jq present/absent). 3 Important hook-robustness gaps + a semantics
decision, all reproduced before fixing.

### Fixed

- **Hook JSON injection.** A `"` in a branch name or lens value (legal in git refs; lens is model-written) broke the block JSON. `emit_block` now strips `"`/`\`/newlines from the reason.
- **Malformed counters blocked instead of failing open.** Non-numeric `cap`/`blocks` in the armed file made bash `-ge` error out and fall through to *blocking* — the opposite of fail-open, with the cap layer dead. All counters are now numeric-validated; ANY malformed value allows (with a stderr re-arm hint).
- **Unslugified fallback thread.** When `thread=` was missing from the armed file on a `feat/x` branch, the hook told Claude to use `--thread review-feat/x`, which the driver rejects — unsatisfiable APPROVE gate until cap. Fallback (and invalid `thread=` values) now slugify `/`→`-`.
- **`/thread-new` dead zone in autoplan.** Release condition changed from `rounds > rounds_at_arming` to `rounds != rounds_at_arming`, so a counter reset followed by a fresh `/plan` run still releases the gate.
- **Orphaned `.rounds`.** The driver no longer bumps the round counter when the thread failed to persist (no `.id`).
- Verdict matcher also accepts the `Verdict: APPROVE` prefixed form (still standalone-line only — the contract line inside logged PROMPTs still cannot fake a verdict).

### Changed

- **`stop_hook_active` is no longer an unconditional allow.** Honoring it capped the gate at one block per user turn, silently breaking the advertised "blocks until APPROVE or cap" contract. The numeric-validated round cap is now the hard terminator (worst case: `cap` review dispatches per arming); docs updated to state the real semantics, including the "arm on a clean tree" warning (pre-existing dirt counts as unverified).
- Manifests' descriptions now list `/debate`, `/autoreview`, `/autoplan`.

### Added

- `tests/hook-regression.sh` — 19-assertion committed regression suite for the Stop hook (the review's repro cases included: quote-in-branch JSON validity, malformed-counter fail-open, slugified fallback, contract-line-vs-verdict, autoplan reset release). Run: `bash tests/hook-regression.sh`.
- Eval-method note: the suite initially failed 3 of its own cases — twice because the harness wrote its stderr capture file *inside* the test repo (dirtying the tree it was asserting clean), once because it armed autoplan with a snapshot the arming command could never produce. Test harnesses are subject to the same isolation rules as eval fixtures.

## [0.4.0] - 2026-06-09

Driven by a field study of the plugin's first production runs (marqa + stokli:
a 5-round plan loop, an 8-round review loop, and a plan thread that absorbed
two unrelated tasks), plus two cross-agent reviews of the analysis.

### Added

- **`/debate`** — structured multi-round disagreement between Claude Code and Codex on a decision, every exchange visible to the user (CC commits to a position BEFORE dispatching, rebuts following the skill's anti-capitulation rules, ends in an honest synthesis that states residual disagreements instead of forcing consensus). New SKILL section "Debating Codex"; RED scenario `debate-capitulation.json` (verdict: INCONSISTENT — haiku under wrap-up pressure concedes the opponent's false premise; rules target exactly that).
- **`/autoreview on|off|status`** — opt-in self-verification gate. A plugin Stop hook blocks the end of any turn with unverified code changes on the armed branch, routing Claude to `/review --thread review-<branch>`; blocking ends on APPROVE in that thread's log, on the round cap (default 3), or on `off`. Runaway-safe three layers deep: `stop_hook_active` re-entrancy flag, blocks-vs-cap counter, APPROVE verdict gate. The hook never calls Codex itself and fails open on any error.
- **`/autoplan on|off|status`** — same gate for plan documents (`docs/plans/**`, `docs/PLANS/**`): a turn that changed plans can't finish until one `/plan` stress-test ran since arming (round-count based; plan verdicts are prose and deliberately not parsed).
- **`--thread <name>`** on `/review` and `/plan` — per-task threads. SKILL routing now states the rule: one task = one thread (`review-<branch>`, `plan-<topic>`). Motivated by a production plan thread that mixed two features and paid every later round's resume re-feeding the first feature's history.
- **Round counter** — the driver tracks `<thread>.rounds` (reset by `--new` and `/thread-new`); `/review`/`/plan` inject "this is round N — re-check your prior findings first and state how close this is to APPROVE/sound" from round 2 on. `/thread-list` now shows rounds and log size.
- **Exhaustive-instances rule** in the shared review contract and all plan lenses: when Codex finds an instance of a problem class it must enumerate ALL sites of that class in the same round — not one per round. Paired with the new SKILL rule **"fix the neighborhood, not the cited line"** for the fixing side (RED scenario `fix-neighborhood.json`; synthetic small-fixture baseline unreproducible, production regime directly documented — 3 rounds burned on one invariant in the stokli run).
- **gitignore hint** — on first thread creation in a repo where `.claude/codex-threads/` is not ignored, the driver warns once (marker-file suppressed) to add it to `.gitignore`. Both real consumer repos had 100KB+ of session logs sitting untracked.

### Verified

- Driver regression (fake codex): rounds counting, `--new` reset, oneshot still traceless (no `.rounds`, no state dir), gitignore-warn fires once and stays silent when ignored.
- Stop hook, 9 synthetic cases: not-armed/clean/wrong-branch/`stop_hook_active`/APPROVE-gate/round-released all allow; armed+dirty and plan-changed block with correct round counters; cap reached allows with an explanatory stderr note; the verdict regex is not fooled by the contract line inside logged PROMPTs.
- Eval-method note for the record: the first `fix-neighborhood` RED attempt was confounded by two parallel cells sharing one fixture file (one agent watched the other's edits appear and attributed them to "a linter"). Re-run with per-cell fixture copies. Lesson: isolate fixtures per cell, same as CWD isolation.

## [0.3.0] - 2026-06-08

### Changed (BREAKING)

- **Dropped the `codex-` prefix from all command names.** Plugin commands are namespaced under the plugin anyway (`/cc-codex-triage:codex-review` had "codex" twice), so the prefix was redundant in the form you actually invoke. New names:
  - `/cc-codex-triage:ask` (was `codex-ask`)
  - `/cc-codex-triage:review` (was `codex-review`)
  - `/cc-codex-triage:plan` (was `codex-plan`)
  - `/cc-codex-triage:reply` (was `codex-reply`)
  - `/cc-codex-triage:thread` / `:thread-list` / `:thread-new` (was `codex-thread*`)
  - Command files renamed accordingly; docs, skill routing table, and scenarios updated.
  - The skill (`codex-triage`), the driver (`scripts/codex-thread.sh`), and the thread state dir (`.claude/codex-threads/`) are **unchanged** — existing threads (`review.id`, `plan.id`, …) keep working after re-install; only the slash-command names changed.
  - **Note on bare forms:** `/review` and `/plan` now collide with Claude Code's built-in commands, so use the namespaced `/cc-codex-triage:review` / `:plan`. `/ask`, `/reply`, `/thread*` have no known collision.

## [0.2.2] - 2026-06-08

Minor tails from the Codex agent's re-review of v0.2.1 (it confirmed all v0.2.1
blockers fixed and `claude plugin tag --dry-run` now passing).

### Fixed

- **Accuracy: resume flag claims.** `codex exec resume` accepts `-m`/`-c` on current Codex CLIs (verified on 0.137.0); only `-s` (sandbox) and `-C` (cwd) are genuinely fixed at session creation. Reworded the driver comment, SKILL.md, scenario, and 0.2.0 changelog line which had said resume "rejects -m/-c". Runtime was already correct (the driver intentionally passes no overrides on resume to keep the thread stable) — only the wording was off.
- **`--oneshot` no longer creates an empty state dir.** The driver created `.claude/codex-threads/` before branching, so a one-shot left an empty directory despite "leaves no trace". The state dir is now created lazily for persistent modes only; a one-shot's failure diagnostics go to a temp path instead.

## [0.2.1] - 2026-06-08

Fixes from a cross-agent review (Codex audited the repo; findings validated
side-by-side against the code, then fixed). 8 of 9 findings were valid.

### Fixed

- **Blocker — broken command frontmatter.** `argument-hint` values starting with `[` were parsed by YAML as a flow sequence, failing the whole frontmatter so `claude plugin validate <plugin-dir>` dropped all metadata (including `allowed-tools` and `disable-model-invocation`) on 5 of 7 commands. All `argument-hint` values are now quoted. (My earlier validation only checked the marketplace manifest, not the plugin dir — now both pass `--strict`.)
- **Blocker — driver crashed on default run.** `"${EXTRA_FLAGS[@]}"` is an "unbound variable" under `set -u` on bash 3.2 (macOS default) when `CC_CODEX_FLAGS` is empty, so `/codex-review`, `/codex-plan`, `/codex-thread` never reached Codex without a custom env var. Switched to the `${arr[@]+"${arr[@]}"}` guard; verified on bash 3.2.57.
- **Mutation guard false positives on its own state dir.** `git status --porcelain` flagged the driver's own `.claude/codex-threads/*.id` writes. The guard now filters that directory and uses `-uall` so the filter survives git's untracked-dir collapse. Verified it still catches a real tracked-file mutation. Also fixed `.gitignore` (`.codex-threads/` → `.claude/codex-threads/`).
- **Diagnostics deleted before they could be read.** Error messages pointed at the JSONL stream, but the EXIT trap removed it. Failures now persist the stream to `<thread>.last-error.jsonl` and point there.
- **`--oneshot` now truly traceless.** It previously still wrote the audit log; the log write is now skipped for one-shots (no `.id`, no `.log`, no rollout).
- **`/codex-reply` no longer silently creates a thread.** New driver flag `--require-existing` (exit 6) makes reply fail-fast when the target thread doesn't exist.
- **Log rotation kept the latest entry.** Rotation now runs *before* the append, so the current `.log` always holds the newest `REPLY:` (previously the fresh entry was moved straight to `.log.1`).

### Documentation

- Corrected install instructions: `/plugin marketplace add clicktronix/cc-codex-triage` + `/plugin install cc-codex-triage@cc-codex-triage` (was the outdated `/plugin add`). Documented that plugin commands are namespaced (`/cc-codex-triage:codex-review`).
- Documented the porcelain guard's known limitation (already-dirty files), and clarified scope: this is a one-directional Claude Code → Codex plugin, intentionally not packaged as a Codex plugin.

### Known / not fixed

- `claude plugin tag --dry-run` reported failing in the review — that is a marketplace-tagging step, separate from plugin validity; deferred.

## [0.2.0] - 2026-06-01

### Added

- `/codex-ask` — informational Q&A in a persistent `ask` thread, defaulting the Codex sandbox to read-only (you're asking, not mutating; never trips the tracked-file guard). Supports `--oneshot`.
- `/codex-reply` — compose a reply from Claude Code back into an active Codex thread (answer a question, run a requested tool action, push back on a finding). Recovers Codex's last message from the thread log.
- `--lens` on `/codex-review` (correctness/security/performance/architecture/ux/quick) and `/codex-plan` (stress-test/pre-mortem/devils-advocate/alternatives/adr). Lens templates live in `skills/codex-triage/references/review-lenses.md` (progressive disclosure). Review lenses share a Conventional Comments output contract + verdict.
- `--oneshot` flag on the driver and all dispatch commands — throwaway via `codex exec --ephemeral`: no `.id` tracked, no rollout persisted. Mutually exclusive with `--new`.
- Skill section "Answering Codex back" and routing table (which command for which intent) in `SKILL.md`. Description broadened to cover asking and replying.
- New scenario `tests/scenarios/codex-triage/reply-tool-request.json`.

### Changed

- `SKILL.md` clarifies that Codex is an agent (it fetches diffs / runs tests itself) — send intent + scope + focus, not project context.
- Driver `--oneshot` branch reuses the porcelain guard and audit log; resume dispatches pass no overrides (sandbox/cwd are fixed at session creation; model/config kept stable across the thread).

### Eval

RED baselines run for the new `/codex-reply` claim (sonnet+neutral, haiku+adversarial; GREEN cells too):

- `reply-tool-request` — **UNREPRODUCIBLE** on the happy path. With a working tool call, both models run the requested command and paste verbatim output unprompted, and neither re-affirms Codex's self-retracted claim. The "Answering Codex back" section was therefore **demoted** from a load-bearing rule to a brief reminder (same treatment as `thread-id-extraction` and `rsc-hybrid-read` before it). A narrower unhappy-path failure (tool fails → guess instead of debug) is noted but untested.

Net across all four scenarios: only `resume-failure-handling` is a consistent RED. The lens templates are canned prompts, not behavioural claims, so they carry no RED requirement.

## [0.1.0] - 2026-05-31

### Added

- `cc-codex-triage` Claude Code plugin scaffold (`.claude-plugin/marketplace.json` + `plugins/cc-codex-triage/.claude-plugin/plugin.json`).
- Skill `codex-triage` describing when to invoke each command, Judge-mode framing rule for third-party reviews (with detection cues and wrapping template), and a Common Failure Modes table covering resume failure, mid-thread sandbox change, `--last` contamination, tracked-file mutation, and sycophantic capitulation.
- Slash commands `/codex-review`, `/codex-plan`, `/codex-thread <name>`, `/codex-thread-list`, `/codex-thread-new <name>`. Each declares `allowed-tools: Bash` and `disable-model-invocation: true` so Claude never auto-fires them.
- Bash driver `scripts/codex-thread.sh`:
  - Initial dispatch via `codex exec --json -C "$CLAUDE_PROJECT_DIR (or pwd)" -o <out>` with strict UUID extraction (`8-4-4-4-12`) from JSONL stream (`thread_id` / `session_id` / `conversation_id` tried in order).
  - Subsequent turns via `codex exec resume --json <UUID> -o <out>` — no `-s`/`-m`/`-c`/`-C` passed (session-immutable).
  - No silent fresh-exec fallback on resume failure (exit code 4) — saved UUID is preserved.
  - Tracked-file mutation guard: `git status --porcelain` snapshot pre/post each Codex dispatch, warn on diff (fatal if `CC_CODEX_TRIAGE_STRICT=1`).
  - Per-thread audit log at `.claude/codex-threads/<name>.log`, rotated at ~1 MB (configurable via `CC_CODEX_TRIAGE_LOG_CAP_BYTES`).
  - Portable `mktemp` (works on macOS BSD and GNU coreutils).
- `tests/scenarios/codex-triage/` — three RED→GREEN scenarios scaffolded under the same contract used by `nextjs-clean-skills/tests/scenarios/`:
  - `judge-mode-paste.json` — guards the Judge-mode framing rule (anti-sycophancy on third-party review paste).
  - `resume-failure-handling.json` — guards "no silent fresh-exec on resume failure" (exit code 4 semantics).
  - `thread-id-extraction.json` — guards the driver's UUID capture from `--json` stdout (no `--last` fallback).
  - Each scenario has `baseline_observed: null` — the skill claims they guard are formally hypotheses until the baselines are reproduced. `tests/scenarios/README.md` documents the format and the run loop.
- MIT license.

### Authoring notes

Self-reviewed against superpowers `writing-skills`, the Anthropic skill-authoring best practices document bundled with it, and the official Claude Code [skills](https://code.claude.com/docs/en/skills) and [plugins-reference](https://code.claude.com/docs/en/plugins-reference) docs. The review surfaced three Critical, eight Major, and ten lesser issues; all were addressed.

RED baselines for the three scenarios were then run against fresh subagents (sonnet+neutral and haiku+adversarial cells, CWD-isolated):

- `judge-mode-paste`: **INCONSISTENT**. Both models construct side-by-side judge framing on their own. The narrow failure that survives is Sonnet+neutral adding "provide a corrected implementation" at the end. SKILL.md was rewritten to specifically forbid that fix-application addendum rather than to teach the side-by-side framing (which neither model needs).
- `resume-failure-handling`: **CONSISTENT RED** under haiku+adversarial. The skill's Common Failure Modes row earns its place specifically for that audience.
- `thread-id-extraction`: **UNREPRODUCIBLE**. Both models independently derive the right architecture even under lazy framing. No SKILL.md section was added — the driver script is the only artifact. Scenario retained as design documentation (precedent: `rsc-hybrid-read` in `nextjs-clean-skills` v1.3 was demoted under the same pattern).

GREEN cells (skill loaded) are the natural v0.2 follow-up — confirm the skill flips the haiku+adversarial resume-failure behaviour and the sonnet+neutral fix-addendum.
