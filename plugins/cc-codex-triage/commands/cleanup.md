---
description: Find and (optionally) archive stale cc-codex-triage state in this repo — stale/pre-0.5 armed gates, orphan thread logs, and contaminated generic threads. Dry-run by default; --apply archives (never deletes).
allowed-tools: Bash
disable-model-invocation: true
---

# /cleanup

Surfaces stale state and, on confirmation, archives it. Never deletes — `--apply`
moves items into a `.archive-<timestamp>-*/` subdir, so it is reversible.

## Steps

1. **Dry run first** — run via Bash and show the output verbatim:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh"
   ```

2. If it found stale/orphan items, summarize them for the user and ask whether to archive. Note that **generic threads (`review`/`plan`) are listed but never auto-archived** — they may be active; the user decides via `/thread-new` or a per-task `--thread`.

3. **Only after the user agrees**, archive (non-destructive — moves to `.archive-<timestamp>-*/`):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup.sh" --apply
   ```

4. Tell the user where things were archived and that restoring is just moving them back. Stale armed gates that were archived can be re-created with `/autoreview on` / `/autoplan on` on the right branch.
