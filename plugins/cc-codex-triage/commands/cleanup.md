---
description: Find and (optionally) archive stale cc-codex-triage state in this repo — stale/pre-0.5 armed gates, orphan thread logs, stale last-error diags, dormant threads (--older-than), and contaminated generic threads. Dry-run by default; --apply archives (never deletes).
allowed-tools: Bash
disable-model-invocation: true
---

# /cleanup

Surfaces stale state and, on confirmation, archives it. Never deletes — `--apply`
moves items into a `.archive-<timestamp>-*/` subdir, so it is reversible.

Detection classes:

- **Stale armed gates** — armed for a branch other than the current one.
- **Pre-0.5 armed gates** — missing `log_bytes_at_arming` (the hook fails open on them).
- **Orphan logs** — a `<thread>.log` with no `<thread>.id` (the thread never persisted).
- **Stale last-error diags** — a `<thread>.last-error.jsonl` whose thread has no
  `.id` (orphan diagnostics) or whose `.log` is newer than the diag (the thread
  recovered after the failure). A diag newer than the log on a persisted thread
  is the thread's live last error and is NOT flagged.
- **Dormant threads** — only with `--older-than <days>` (integer **≥ 1**, max
  5 digits; `0`, negatives, non-numbers, and longer values are rejected — a
  leading-zero value like `08` is read base-10 as 8): a thread's whole file-set
  (`id, log, log.1, rounds, findings.jsonl, scope, approved, last-error.jsonl,
  detach-output, detach-stderr, detach-status, active`) qualifies when its
  NEWEST member is older than N days. Listed on dry run, moved wholesale on `--apply`.
- **Generic threads** — `review`/`plan` default threads. Listed only, never
  auto-archived.

Safety rails (in precedence order), enforced uniformly by **every** detection
class through one shared rail check:

1. **Live lease** — while `<thread>.active` names a live PID, a dispatch is in
   flight (a resume waiting inside `codex exec` may write nothing until it
   returns): the thread is skipped unconditionally. A dead-PID or malformed
   lease is itself stale state and joins the archivable set in every class.
2. **Armed targets** — a thread named by `autoreview.armed`/`autoplan.armed`
   `thread=` lines is never archived, whichever class flagged it.
3. **Revalidate before move** — on `--apply`, EVERY target (flat file or
   dormant set) is re-checked immediately before moving: the lease/armed rails
   re-run per thread, and mtimes are re-stat'ed; anything that changed since
   detection (a re-armed gate, a refreshed diag, a woken thread) is skipped
   with a note.
4. Generic `review`/`plan` threads stay list-only (rule above), in every class.

## Steps

1. **Dry run first** — run via Bash and show the output verbatim (add
   `--older-than <days>` only when the user asked to sweep dormant threads —
   30 is a sensible default to suggest):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh"
   # or, including dormant threads:
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh" --older-than 30
   ```

2. If it found stale/orphan/dormant items, summarize them for the user and ask
   whether to archive. Note that **generic threads (`review`/`plan`) are listed
   but never auto-archived** — they may be active; the user decides via
   `/thread-new` or a per-task `--thread`. Threads reported `IN USE` (live
   dispatch) or `SKIP` (armed-gate target) are excluded automatically.

3. **Only after the user agrees**, archive (non-destructive — moves to
   `.archive-<timestamp>-*/`; repeat the same `--older-than` value used in the
   dry run):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh" --apply
   # or, including dormant threads:
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh" --older-than 30 --apply
   ```

4. Tell the user where things were archived and that restoring is just moving
   them back. Stale armed gates that were archived can be re-created with
   `/autoreview on` / `/autoplan on` on the right branch.
