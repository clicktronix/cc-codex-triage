---
description: Accept a recorded review finding as a known/intentional limitation — mark it accepted in the ledger with a reason, so it stops counting as open.
argument-hint: "[--thread <name>] <finding-id> --reason <why this is acceptable>"
allowed-tools: Bash
disable-model-invocation: true
---

# /review-accept

For a valid finding you are intentionally NOT fixing (a deliberate trade-off, an out-of-scope concern, an acceptable risk): record the decision with a reason so it stops holding up `--continue` / the open list, and the rationale is auditable.

## Steps

1. Parse `--thread <name>` (default `review-<branch-slug>`), the finding `<id>`, and the `--reason` text.

2. Confirm it exists: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" get <THREAD> <id>`.

3. Record the acceptance:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" status <THREAD> <id> accepted --note "<reason>"
   ```

4. Tell the user it is recorded as accepted (with the reason). A blocking finding accepted this way no longer blocks — make sure the user actually agreed to the trade-off, don't accept on their behalf to release a gate.
