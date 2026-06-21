---
description: Dispute a recorded review finding by id — rebut it to Codex with file:line evidence and mark it false-positive in the ledger.
argument-hint: "[--thread <name>] <finding-id> <why it is wrong, with file:line>"
allowed-tools: Bash
disable-model-invocation: true
---

# /review-dispute

For a finding you believe is wrong: push back on Codex with concrete evidence and record the rejection, instead of silently ignoring it (which would leave it "open" forever) or applying it to make the gate release.

## Steps

1. Parse `--thread <name>` (default `review-<branch-slug>`; bare `review` only if that is where the finding lives) and the finding `<id>` (e.g. `f3`); the rest is your rebuttal.

2. Confirm the finding exists: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" get <THREAD> <id>`.

3. **Verify your rebuttal against the code first** (per skill `codex-triage` — validating inbound findings): read the cited site and its consumers and quote the file:line that refutes the finding. Do not dispute on a hunch.

4. Send the rebuttal to Codex so it can confirm or hold its ground — follow `${CLAUDE_PLUGIN_ROOT}/commands/reply.md` with the same `<THREAD>`, quoting the refuting file:line. Show Codex's reply verbatim.

5. If Codex concedes (or you have decisive file:line evidence it cannot refute), mark it:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh" status <THREAD> <id> false-positive --note "refuted: <file:line>"
   ```
   If Codex holds a finding you still believe is wrong, **escalate to the user** — do not flip it to false-positive just to clear the list.
