# Skill evaluation scenarios

RED→GREEN→REFACTOR scenarios for the `codex-triage` skill, following the same
contract used in `nextjs-clean-skills/tests/scenarios/` and the superpowers
`writing-skills` Iron Law.

## Iron Law

**NO SKILL CHANGE WITHOUT A FAILING TEST FIRST.** Every load-bearing claim in
`SKILL.md` MUST have a scenario file here with a reproduced `baseline_failure`
(RED) before that claim earns its place in the skill body. Claims without
reproduced baselines are *hypotheses*, not validated guidance — they may be
redundant (strong models already do the right thing), narrowly-scoped, or
plain wrong.

This rule applies to **new claims AND edits**. Editing a claim resets its
baseline.

## Format

Each scenario records the TDD cycle for one load-bearing claim:

```json
{
  "skills": ["codex-triage"],
  "tests_reference": "skills/codex-triage/SKILL.md#<anchor>",
  "query": "the task given to the agent",
  "baseline_failure": "RED: what the agent does without the skill",
  "expected_behavior": ["GREEN bullet", "GREEN bullet"],
  "anti_expectation": ["overreach the agent must not do"],
  "baseline_observed": null
}
```

Once baselines are run, fill in `baseline_observed`:

```json
"baseline_observed": {
  "date": "YYYY-MM-DD",
  "method": "1-line summary of how the runs were dispatched (fresh subagent, no skill loaded, paste prompt, record verbatim output)",
  "runs": [
    { "model": "haiku", "framing": "adversarial", "red": true, "note": "..." },
    { "model": "sonnet", "framing": "neutral", "red": false }
  ],
  "verdict": "is the baseline consistent, inconsistent, or unreproducible? If unreproducible, the corresponding skill claim should be demoted to one prose line or deleted (see nextjs-clean-skills rsc-hybrid-read precedent)."
}
```

## Running

There is no built-in LLM-judge runner. Run manually:

1. **RED:** open a fresh agent session with the skill *disabled*, paste
   `query`, confirm `baseline_failure` is reproduced. Record verbatim.
   If it doesn't fail, delete the scenario and the skill claim it guards.
2. **GREEN:** new session with the skill *enabled*, same `query`, confirm
   `expected_behavior`.
3. **REFACTOR:** vary `query` toward `anti_expectation`, confirm the agent
   does not over-apply.

**Test against every model the skill targets.** Strong models may treat the
guidance as obvious; weak models under lazy framing reveal the real failure
mode.

**Harness limitation — isolate CWD.** A baseline agent that inherits a real
project's working directory will explore it and may produce false passes by
mimicking existing patterns. Run in an empty/throwaway directory or
explicitly tell the agent "do not read files; this is a hypothetical."

## Current status

All three scenarios below have `baseline_observed: null` — they are
**scaffolded but not yet run**. Until they are run and the verdicts recorded,
the corresponding sections in `SKILL.md` are formally hypotheses. They are
kept in the skill body for now because the rationale (sycophancy paper,
Codex CLI session semantics) is documented; they may need to be demoted if
baselines turn out to be unreproducible.

- `judge-mode-paste.json` — guards the Judge-mode framing rule in SKILL.md
- `resume-failure-handling.json` — guards the "no silent fresh-exec on resume failure" rule
- `thread-id-extraction.json` — guards the driver's `thread_id` capture from `--json` stdout
