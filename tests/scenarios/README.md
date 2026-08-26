# Historical skill evidence

These JSON files record small prompt probes and production observations that
informed `codex-triage`. They are evidence, not an executable test suite and not
a requirement to manufacture a RED result for every wording change.

Use evidence in proportion to risk:

- Prefer deterministic shell tests for scripts, state, and delivery gates.
- Use a prompt probe only for behavior that cannot be checked deterministically.
- Record unreproduced claims as hypotheses; do not promote them to mandatory
  skill prose merely to make a scenario pass.
- Keep production observations when the failure needs real multi-round scale,
  and label that limitation in the JSON.

The retained scenarios have either a reproduced failure, a narrow split result,
or a documented production failure. Three unreproduced probes were removed:
thread-id extraction is implementation detail, tool-request compliance was
already normal model behavior, and inbound-finding validation remains a short
risk-derived rule rather than a claim of measured failure.

There is no LLM judge or automatic GREEN label here. Re-run a scenario only
when changing the behavior it describes, preserve the prompt and raw outcome,
and report mixed results honestly.

`tests_reference` points to the current owner of the behavior. When that owner
replaced a more verbose rule, `historical_reference` preserves the section that
the recorded observation originally evaluated; it is provenance, not a live
contract.
