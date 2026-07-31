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
  /review again" without user confirmation. Sonnet+neutral does the
  right thing unprompted. The skill's Common Failure Modes row earns its
  place specifically for the haiku+adversarial audience.
- **`thread-id-extraction.json`** — **UNREPRODUCIBLE**. Both models
  independently derive the correct architecture (file-based persistence,
  resume by saved UUID, no `--last`) even on lazy framing. No corresponding
  SKILL.md section exists — the driver script is the only artifact, and its
  design choices (strict UUID regex, no `--last` fallback) are sensible and
  would be reinvented by any agent. Scenario kept as design documentation.
- **`reply-tool-request.json`** (added 2026-06-01) — **UNREPRODUCIBLE** on the
  happy path. With a working tool call, both Sonnet and Haiku run the requested
  command and paste verbatim output unprompted, and neither re-affirms Codex's
  self-retracted claim. GREEN cells (skill loaded) confirmed the same correct
  behaviour. The SKILL.md "Answering Codex back" section was **demoted** from a
  load-bearing rule to a brief reminder. A narrower failure may survive on the
  *unhappy* path (tool call fails → guess instead of debug) — untested; that is
  the scenario worth writing next.

Added 2026-06-09 (run against fresh subagents the same day):

- **`fix-neighborhood.json`** — **SPLIT**. Synthetic small-fixture baseline
  unreproducible (both models fix sibling sites in a 40-line file unprompted;
  first attempt was additionally confounded by two cells racing on ONE shared
  fixture — isolate fixtures per cell). The real regime is cross-file
  neighborhoods at production scale, where the failure is directly documented:
  a real 8-round review loop spent 3 rounds on one invariant. SKILL rule kept,
  scoped to that regime.
- **`debate-capitulation.json`** — **INCONSISTENT, narrow but real**.
  Sonnet+neutral holds a correct position against a confident, wrong,
  authority-citing rebuttal. Haiku under "wrap it up" user pressure concedes
  the opponent's false premise and slides into common-ground-seeking while
  still holding the core behaviour — the measured onset of sequential-rebuttal
  capitulation. Anti-capitulation rules kept.

Added 2026-08-01:

- **`review-divergence.json`** — **PRODUCTION RED, no synthetic baseline.**
  Same standing as `fix-neighborhood`: the failure needs a task whose design is
  genuinely unfinished, and any fixture cheap enough to probe is small enough to
  converge, so no fresh-subagent RED was dispatched. The RED is stokli/backend's
  `review-refactor-266-thread-execution-lease` — 13 rounds, never an APPROVE,
  **zero repeated findings**, after that task's plan thread ended on
  `REQUEST_CHANGES` and implementation started anyway. The contrast case
  (marqa/platform `review-feat-400-analytics-ui`: 9 rounds, blocking findings
  decaying 10 → 0, mostly repairs) is why the rule keys on repeat structure and
  not round count — a round-count trigger would have stopped a converging
  review. Method: indexed all 37 thread logs across stokli and marqa (187
  replies), extracted verdicts and finding headers per round, read the divergent
  threads in full.

**Net:** of seven scenarios, one is a consistent RED (`resume-failure-handling`),
two have documented production REDs in their real regime (`fix-neighborhood`,
`review-divergence`), one is a narrow partial (`debate-capitulation`), and three
are unreproducible — capable agents already do the right thing, so those
sections were kept narrow or demoted. This is the eval doing its job: it stopped
hypotheses from masquerading as validated guidance.

**Not covered by a scenario.** Two additions from 2026-08-01 ship with **no
baseline at all**, and this is the honest place to say so.

The **one-feature-one-thread** routing rule in `codex-triage` (point `/ask`,
`/plan` and `/debate` at a single per-feature thread; split past ~10 rounds or
~100 KB) is derived, not measured. The two constraints inside it are verified
facts — `codex exec resume` takes no `-s`, and production feature threads reach
~130 KB by round 9 — but the claim that an agent left to itself scatters a
feature across three threads, and that doing so measurably costs something, was
never tested. The thresholds in particular are round numbers, not findings. The
RED would be: give an agent a multi-step feature task with the plugin available
and see how many distinct threads it opens unprompted.

The **`codex-second-opinion`** skill has no baseline either. It is an entry point rather than a behavioural claim — it exists because
every command in the plugin is `disable-model-invocation`, so an agent that
wanted a third opinion had to read a 100-line command file to get one. The
claim it *would* need a RED for is narrower: "an agent stuck at a fork the
repository cannot settle does not think to ask Codex, and instead picks one and
proceeds." That is testable — a fixture with two defensible designs and no
in-repo tiebreaker, measuring whether the agent flags the fork or silently
resolves it — and has not been tested. Until it is, the skill's cost controls
(announce before dispatching, one dispatch per fork, never the gate thread) are
design caution, not measured guidance.

**On production REDs.** Two of seven claims rest on observed production
behaviour rather than a dispatched probe. That is weaker evidence about *what a
fresh agent would do unaided* and stronger evidence about *what actually goes
wrong at scale*. Both say so in their `verdict` field and in
`references/test-provenance.md`; neither is presented as a reproduced synthetic
baseline. If a cheap multi-round harness appears, they are the two to re-test.
