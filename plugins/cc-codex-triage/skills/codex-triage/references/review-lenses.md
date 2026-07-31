# Review & plan lenses

Canned INSTRUCTION blocks injected into the Codex prompt by `/review` and
`/plan`. These are **templates**, not behavioural rules — pick the block
matching the `--lens` argument, substitute it into the payload, and pipe to the
driver. No lens = the default for that command.

Codex runs as an agent: it will `git diff`, read files, and run tests on its own.
The lens tells it **what to look for and how to report**, not what to fetch.

Each lens is a `<task>` (the lens's focus) plus an "Include blocks" list of
reusable `<...>` prompt blocks. To build the INSTRUCTION: take the lens's
`<task>` content, then append the full text of each block named in its
"Include blocks" line, in the order listed.

## Contents

- Reusable prompt blocks: output_contract, json_output_contract, grounding_rules, exhaustive_per_class, dig_deeper_nudge, verification_loop, plan_verdict
- Review lenses: correctness (default), security, performance, architecture, ux, quick
- Plan lenses: stress-test (default), pre-mortem, devils-advocate, alternatives, adr

---

## Reusable prompt blocks

Defined once here, referenced by name from each lens below.

```xml
<!-- output_contract: shared by ALL review lenses. Replaces the prose "Shared review output contract". -->
<output_contract>
Output ONLY findings, in Conventional Comments format:
  <label> [decoration]: <subject>

  <body: what, why it matters, recommended fix>
Labels: issue | suggestion | question | nitpick | praise | todo | chore | note
Decorations: (blocking) | (non-blocking) | (if-minor)
Cite file:line for every finding. Do NOT restate the diff. Do NOT edit files — report only.
Skip nitpicks unless a file has no higher-severity finding; skip praise unless non-obviously well done.
On a follow-up round, report only what CHANGED: findings whose status moved (resolved / partial /
not addressed) and genuinely new ones. Every still-open non-blocking item from earlier rounds is
carried as ONE line at the end — `carried over (non-blocking): <count> — <short titles>` — never
re-stated as a block. Re-listing an unchanged nitpick in full makes a converging round read as a
stalled one and buys another round for nothing.
End your message with the verdict ALONE on its own final line — exactly APPROVE, REQUEST_CHANGES or
COMMENT and nothing else on that line. Not `**Final review decision: APPROVE.**`, not a sentence that
happens to contain the word: a program reads that line to decide whether the review loop is finished,
and a verdict buried in prose reads as no verdict at all. Use REQUEST_CHANGES only when at least one
(blocking) finding remains.
Honour AGENTS.md if present.
</output_contract>

<!-- json_output_contract: used ONLY by /review --json. Swaps OUT the output_contract block (never both — contradictory instructions hurt quality). -->
<json_output_contract>
Return your FINAL message as JSON conforming to the provided output schema — nothing else: no prose, no Conventional Comments, no verdict line outside the JSON.
Populate every finding's file, line_start, severity (blocking|non-blocking), confidence (0..1), title, body, and recommendation. Set the top-level verdict to APPROVE | REQUEST_CHANGES | COMMENT.
</json_output_contract>

<grounding_rules>
Ground every claim in the repository context or tool outputs you inspected.
If a point is an inference, label it clearly. Do not assert unsupported certainty.
</grounding_rules>

<dig_deeper_nudge>
Before finalizing, check for second-order failures, empty/null/boundary states, retries, stale state, and rollback paths.
</dig_deeper_nudge>

<verification_loop>
Before finalizing, verify each finding is material and actionable, and that the verdict matches the findings.
</verification_loop>

<exhaustive_per_class>
When you find an instance of a problem class, search for ALL other sites of the same class and list every one in THIS round — do not dole out one per round.
</exhaustive_per_class>

<!-- plan_verdict: shared by ALL plan lenses. Exhaustiveness rule plus the machine verdict, so /status and tooling can read the plan's verdict instead of guessing from prose. -->
<plan_verdict>
When you find a gap of some class (e.g. an uncovered ingress path, a missing
rollback step), enumerate ALL instances of that class in this round — do not
surface one per round.

End your message with the verdict ALONE on its own final line — exactly
APPROVE, REQUEST_CHANGES or COMMENT and nothing else on that line, not a
sentence that happens to contain the word. A program reads that line.
APPROVE = the plan is sound to execute as written; REQUEST_CHANGES = at least
one blocking gap remains; COMMENT = only minor or optional concerns. Use
REQUEST_CHANGES only for a genuinely blocking gap — do not hold APPROVE on
nice-to-haves.
</plan_verdict>
```

---

## Review lenses

### correctness (default)

```xml
<task>
Deep correctness review against the stated intent. Apply, where relevant, the
standard reviewer checklist: design, functionality, complexity, tests, naming,
comments, consistency, documentation. Prioritise: logic bugs, unhandled edge
cases (empty/null/boundary/error paths), broken invariants, missing tests for
new behaviour, and scope gaps vs the intent (intended but not implemented).
</task>

Include blocks: <grounding_rules> <exhaustive_per_class> <dig_deeper_nudge> <verification_loop> <output_contract>
```

### security

```xml
<task>
Security-focused review. Check each, skip if N/A:
- Input validation & sanitisation before use
- Auth / authz on every protected path; privilege escalation
- Injection: SQL, XSS, command, path traversal, SSRF
- Secrets: nothing hardcoded or logged
- Data integrity: partial writes, missing transactions, race/TOCTOU
- Safe errors: no stack traces or internals leaked to users
Skip style and performance unless they create a security issue.
</task>

Include blocks: <grounding_rules> <exhaustive_per_class> <output_contract>
```

### performance

```xml
<task>
Performance review. Look for: N+1 queries, unindexed lookups, sync I/O on hot
paths, unbounded memory growth, missing pagination, redundant recompute that
should be memoised/cached, and chatty network calls that should batch. Flag
only changes with a plausible real-world cost — name the trigger condition
(data size, request rate) for each. Skip micro-optimisations with no measurable
impact.
</task>

Include blocks: <grounding_rules> <output_contract>
```

### architecture

```xml
<task>
Architecture review. Assess: layering/boundary violations, circular deps,
leaking abstractions, the change living in the wrong layer, business logic in
controllers/views, missing seams for testing, and consistency with existing
patterns in this codebase. Judge against the intent's declared design, not an
idealised one. Prefer one structural finding over many cosmetic ones.
</task>

Include blocks: <grounding_rules> <output_contract>
```

### ux

```xml
<task>
Front-end / UX review. Check: loading / empty / error states present, layout
under narrow and wide viewports, keyboard navigation and focus order, colour
contrast and other a11y basics, form validation feedback, and hydration or
flash-of-content issues. If a dev server is reachable you may inspect the
running UI; otherwise review the code and say UX was not exercised live.
</task>

Include blocks: <grounding_rules> <output_contract>
```

### quick

```xml
<task>
Fast smoke review only. Surface blocking issues a reviewer would catch in 60
seconds: obvious bugs, broken/missing tests, secrets, syntax that won't run.
Do not do a deep pass. Keep it to the top few findings or "no blockers found".
</task>

Include blocks: <output_contract>
```

---

## Plan lenses

Plan lenses do NOT use the Conventional Comments findings format (that is for
code). Each is a standalone INSTRUCTION for `/plan`, built the same way as a
review lens: `<task>` plus its included blocks. All five share `<plan_verdict>`
(defined above in the reusable prompt blocks library) — the exhaustiveness rule
plus the same machine verdict reviews use, so `/status` and tooling can read the
plan's verdict instead of guessing from prose. (Note: the `/autoplan` gate
itself still releases on log-growth, not the verdict; verdict-gating the plan
gate is a future change.)

### stress-test (default)

```xml
<task>
Stress-test this plan. Find: missing steps, hidden dependencies, wrong
sequencing, risk areas (data loss, downtime, irreversibility), rollback gaps,
and unstated assumptions. The goal is fixed; the approach is not. Prefer one
strong objection over several weak ones. If the plan is sound, say so plainly.
</task>

Include blocks: <plan_verdict>
```

### pre-mortem

```xml
<task>
Pre-mortem: assume it is six months later and this plan FAILED in production.
Write the post-incident summary — what went wrong, which step or assumption
caused it, and what early warning sign was missed. Then list the 2-3 changes to
the plan that would most reduce that failure probability.
</task>

Include blocks: <plan_verdict>
```

### devils-advocate

```xml
<task>
Argue AGAINST this plan as hard as you honestly can. Make the strongest case
that it should NOT be done, or not this way. Steelman the alternative of doing
nothing. After the argument, state honestly whether the objections are decisive
or survivable.
</task>

Include blocks: <plan_verdict>
```

### alternatives

```xml
<task>
Propose 2-3 alternative approaches to the same goal. For each: one-line
summary, main trade-off, and when it would beat the proposed plan. End with
which you would choose and why — it is fine to endorse the original.
</task>

Include blocks: <plan_verdict>
```

### adr

```xml
<task>
Write an Architecture Decision Record for this plan:
- Context: the forces and constraints
- Decision: what is being chosen
- Consequences: what becomes easier and what becomes harder
- Alternatives considered: and why rejected
Keep each section tight. This is a record, not an essay.
</task>

Include blocks: <plan_verdict>
```
