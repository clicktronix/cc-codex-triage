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

Baselines reproduced 2026-05-31 against fresh subagents (sonnet+neutral and
haiku+adversarial cells, n=1 each, CWD-isolated via "do not use tools"
instruction):

- **`judge-mode-paste.json`** — **INCONSISTENT**. Both models construct
  side-by-side judge framing on their own. The narrow failure that survives
  without the skill is Sonnet+neutral adding "provide a corrected
  implementation" at the end (violates `anti_expectation`). SKILL.md was
  rewritten to specifically forbid the fix-application addendum, not to
  teach the side-by-side framing (which is unnecessary).
- **`resume-failure-handling.json`** — **CONSISTENT RED** under
  haiku+adversarial. The weak+lazy path defaults to "Start fresh: Run
  /codex-review again" without user confirmation. Sonnet+neutral does the
  right thing unprompted. The skill's Common Failure Modes row earns its
  place specifically for the haiku+adversarial audience.
- **`thread-id-extraction.json`** — **UNREPRODUCIBLE**. Both models
  independently derive the correct architecture (file-based persistence,
  resume by saved UUID, no `--last`) even on lazy framing. No corresponding
  SKILL.md section exists — the driver script is the only artifact, and its
  design choices (strict UUID regex, no `--last` fallback) are sensible and
  would be reinvented by any agent. Scenario kept as design documentation.

GREEN cells (skill loaded) are not yet recorded — only RED was tested. For
the scenarios whose baseline failure was reproduced (resume-failure under
haiku+adversarial, judge-mode anti_expectation under sonnet+neutral),
running the GREEN counterpart with the skill loaded would confirm the skill
flips the behaviour. That is the natural v0.2 follow-up.
