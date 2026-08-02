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

## When the review loop is the wrong tool

> **Status:** **PRODUCTION RED, no synthetic baseline** — run 2026-08-01 (`tests/scenarios/codex-triage/review-divergence.json`). Same standing as *fix the neighborhood*: the failure only exists at production scale, because it needs a task whose design is genuinely unfinished, and any fixture cheap enough to probe is small enough to converge. No fresh-subagent RED was dispatched.
>
> **The RED:** stokli/backend `review-refactor-266-thread-execution-lease` — 13 rounds over three days, 15 replies, never an APPROVE, and **not one repeated finding**. Each round produced 2–5 new blocking classes (billing fence, terminal-error idempotency, finalizer lease, checkpoint recovery, SSE generation switching). The same task's plan thread had ended at round 6 on `REQUEST_CHANGES` — *"these are executable contradictions and safety gaps, not optional cleanup"* — the day before implementation started. The review loop paid the difference at one Codex dispatch per design decision.
>
> **The contrast case, and why the rule keys on repeat structure rather than round count:** marqa/platform `review-feat-400-analytics-ui` also ran long — 9 rounds — but its blocking findings decay 10 → 6 → 3 → 4 → 2 → 2 → 2 → 1 → 0 and most rounds are repairs of prior findings, one invariant surviving rounds 4–8. That thread was converging; a round-count trigger would have stopped it wrongly. Method: indexed all 37 thread logs across stokli and marqa (187 replies), extracted verdicts and finding headers per round, read the divergent threads in full.
