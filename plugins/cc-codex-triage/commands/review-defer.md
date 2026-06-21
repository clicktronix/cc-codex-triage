---
description: Defer a recorded review finding to a tracked issue — mark it deferred in the ledger with the issue reference, so it leaves the open list without being lost.
argument-hint: "[--thread <name>] <finding-id> --issue <url-or-ref>"
allowed-tools: Bash
disable-model-invocation: true
---

# /review-defer

For a valid finding that is real but out of scope for this change: record it as deferred with a pointer to where it is now tracked, so it stops blocking here but is not forgotten.

## Steps

1. Parse `--thread <name>` (default `review-<branch-slug>`), the finding `<id>`, and the `--issue <url-or-ref>` (a GitHub issue, ticket, or TODO ref).

2. Confirm it exists: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" get <THREAD> <id>`.

3. Record the deferral:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" status <THREAD> <id> deferred --note "tracked: <issue>"
   ```

4. Confirm to the user, and if no issue exists yet, offer to create one (`gh issue create`) so "deferred" points at something real rather than disappearing.
