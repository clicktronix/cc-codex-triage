# Test provenance — RED baselines behind the SKILL.md rules

Maintainer record: when each behavioural rule was baseline-tested, what reproduced,
and how strongly the rule earned its place. Execution guidance lives in SKILL.md;
this file only calibrates *how strong* each rule is. Scenario paths refer to the
plugin's **source repo** (`tests/scenarios/codex-triage/`), not the installed plugin.

## Judge-mode framing

> **Status:** RED baseline reproduced 2026-05-31 (see `tests/scenarios/codex-triage/judge-mode-paste.json`). Verdict: **INCONSISTENT**. Both Sonnet and Haiku already construct side-by-side framing on their own. The actual failure that survives without this skill is narrower: Sonnet under neutral framing tacks on *"provide a corrected implementation that addresses the valid issues"* — turning Codex into a fix-applier instead of a judge. **That** is what this rule prevents.

## Answering Codex back (`/reply`)

> **Status:** RED baseline run 2026-06-01 (`tests/scenarios/codex-triage/reply-tool-request.json`) — **did NOT reproduce** on the happy path. With a working tool call, both Sonnet and Haiku ran the command and pasted real output unprompted, and neither re-affirmed Codex's self-retracted claim. Kept as a brief reminder, not a strong rule. A narrow failure may remain when the tool call itself **fails** (lazy path = guess the output instead of debugging) — untested.

## Debating Codex — anti-capitulation rules

> **Status:** RED run 2026-06-09 (`tests/scenarios/codex-triage/debate-capitulation.json`) — **INCONSISTENT, narrow but real**. Sonnet+neutral holds a correct position unaided; Haiku under "wrap it up" pressure concedes the opponent's false premise ("you're right that RFC allows retry") and slides into common-ground-seeking, while still holding the core behaviour. These rules target that premise-level capitulation onset (the first stage of the 23.5–80.3% collapse measured in arXiv 2509.16533).

**Rule-narration leak, observed in production:** the "argue, don't narrate the rules" bullet exists because rule labels leaked into a real debate — marqa `debate-product-functional-additions`, 2026-06-14: *"Но из твоего же доказательства следует residual-решение, на котором не уступаю — SEQUENCING плацдарма"*.

## Validating inbound Codex findings

> **Status:** RED run 2026-06-11 (`tests/scenarios/codex-triage/inbound-finding-validation.json`) — **did NOT reproduce** on strong models when the refuting evidence is in-context: both cells (neutral, and under APPROVE-gate + "тороплюсь" pressure) traced a wrong-in-context CRITICAL to the code, refused to merge the regression Codex's fix would introduce, and pushed back with file:line. Kept as a brief reminder for two reasons: (1) both agents justified verifying by citing `superpowers:receiving-code-review` **by name** — a skill most plugin users don't have installed, so the right behaviour was depending on a dependency the plugin doesn't ship; this section encodes the principle inline. (2) The test handed over the refuting code; the untested real failure is laziness about *going to read the files* when a finding looks plausible and the gate/user push for speed.

## Fix the neighborhood

> **Status:** RED run 2026-06-09 (`tests/scenarios/codex-triage/fix-neighborhood.json`) — **SPLIT**. On a small single-file fixture both models fix sibling sites unprompted (synthetic baseline unreproducible). The rule's regime is **cross-file / cross-call-chain neighborhoods at production scale**, where the failure is directly documented: a real 8-round review loop spent 3 rounds on ONE invariant because each fix patched exactly the cited site (first element → all elements → correct ordering).
