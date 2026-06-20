# Review & plan lenses

Canned INSTRUCTION blocks injected into the Codex prompt by `/review` and
`/plan`. These are **templates**, not behavioural rules — pick the block
matching the `--lens` argument, substitute it into the payload, and pipe to the
driver. No lens = the default for that command.

Codex runs as an agent: it will `git diff`, read files, and run tests on its own.
The lens tells it **what to look for and how to report**, not what to fetch.

## Contents

- Shared review output contract (Conventional Comments + verdict)
- Review lenses: correctness (default), security, performance, architecture, ux, quick
- Plan lenses: stress-test (default), pre-mortem, devils-advocate, alternatives, adr

---

## Shared review output contract

Append this to every `/review` lens (all review lenses share it):

```
Output ONLY findings, using Conventional Comments format:
  <label> [decoration]: <subject>

  <body: what, why it matters, recommended fix>

Labels: issue | suggestion | question | nitpick | praise | todo | chore | note
Decorations: (blocking) | (non-blocking) | (if-minor)

Rules:
- Cite file:line for every finding.
- Exhaustive per class: when you find an instance of a problem class (broken
  invariant, missing guard, unchecked path), search for ALL other sites of the
  same class — sibling functions, parallel code paths, other ingress points —
  and list every one in THIS round under the same finding. Do not dole out one
  instance per round.
- Skip nitpicks unless a file has no higher-severity finding.
- Skip praise unless something is non-obviously well done.
- Do NOT restate the diff. Do NOT edit files — report only.
- Last line is the verdict: APPROVE | REQUEST_CHANGES | COMMENT.
  Use REQUEST_CHANGES only when at least one (blocking) finding remains. If the
  open items are all (non-blocking)/(if-minor) — test hygiene, naming, optional
  cleanups — use COMMENT (or APPROVE when nothing is left). Do not hold the
  verdict on nitpicks.
Honour AGENTS.md if present.
```

---

## Review lenses

### correctness (default)

```
Deep correctness review against the stated intent. Apply, where relevant, the
standard reviewer checklist: design, functionality, complexity, tests, naming,
comments, consistency, documentation. Prioritise: logic bugs, unhandled edge
cases (empty/null/boundary/error paths), broken invariants, missing tests for
new behaviour, and scope gaps vs the intent (intended but not implemented).
```

### security

```
Security-focused review. Check each, skip if N/A:
- Input validation & sanitisation before use
- Auth / authz on every protected path; privilege escalation
- Injection: SQL, XSS, command, path traversal, SSRF
- Secrets: nothing hardcoded or logged
- Data integrity: partial writes, missing transactions, race/TOCTOU
- Safe errors: no stack traces or internals leaked to users
Skip style and performance unless they create a security issue.
```

### performance

```
Performance review. Look for: N+1 queries, unindexed lookups, sync I/O on hot
paths, unbounded memory growth, missing pagination, redundant recompute that
should be memoised/cached, and chatty network calls that should batch. Flag
only changes with a plausible real-world cost — name the trigger condition
(data size, request rate) for each. Skip micro-optimisations with no measurable
impact.
```

### architecture

```
Architecture review. Assess: layering/boundary violations, circular deps,
leaking abstractions, the change living in the wrong layer, business logic in
controllers/views, missing seams for testing, and consistency with existing
patterns in this codebase. Judge against the intent's declared design, not an
idealised one. Prefer one structural finding over many cosmetic ones.
```

### ux

```
Front-end / UX review. Check: loading / empty / error states present, layout
under narrow and wide viewports, keyboard navigation and focus order, colour
contrast and other a11y basics, form validation feedback, and hydration or
flash-of-content issues. If a dev server is reachable you may inspect the
running UI; otherwise review the code and say UX was not exercised live.
```

### quick

```
Fast smoke review only. Surface blocking issues a reviewer would catch in 60
seconds: obvious bugs, broken/missing tests, secrets, syntax that won't run.
Do not do a deep pass. Keep it to the top few findings or "no blockers found".
```

---

## Plan lenses

Plan lenses do NOT use the Conventional Comments findings format (that is for
code). Each is a standalone INSTRUCTION for `/plan`. Append this block to every
plan lens (the exhaustiveness rule plus the same machine verdict reviews use, so
`/status` and tooling can read the plan's verdict instead of guessing from prose
— note the `/autoplan` gate itself still releases on log-growth, not the verdict;
verdict-gating the plan gate is a future change):

```
When you find a gap of some class (e.g. an uncovered ingress path, a missing
rollback step), enumerate ALL instances of that class in this round — do not
surface one per round.

End with a standalone verdict line: APPROVE | REQUEST_CHANGES | COMMENT.
APPROVE = the plan is sound to execute as written; REQUEST_CHANGES = at least
one blocking gap remains; COMMENT = only minor or optional concerns. Use
REQUEST_CHANGES only for a genuinely blocking gap — do not hold APPROVE on
nice-to-haves.
```

### stress-test (default)

```
Stress-test this plan. Find: missing steps, hidden dependencies, wrong
sequencing, risk areas (data loss, downtime, irreversibility), rollback gaps,
and unstated assumptions. The goal is fixed; the approach is not. Prefer one
strong objection over several weak ones. If the plan is sound, say so plainly.
```

### pre-mortem

```
Pre-mortem: assume it is six months later and this plan FAILED in production.
Write the post-incident summary — what went wrong, which step or assumption
caused it, and what early warning sign was missed. Then list the 2-3 changes to
the plan that would most reduce that failure probability.
```

### devils-advocate

```
Argue AGAINST this plan as hard as you honestly can. Make the strongest case
that it should NOT be done, or not this way. Steelman the alternative of doing
nothing. After the argument, state honestly whether the objections are decisive
or survivable.
```

### alternatives

```
Propose 2-3 alternative approaches to the same goal. For each: one-line
summary, main trade-off, and when it would beat the proposed plan. End with
which you would choose and why — it is fine to endorse the original.
```

### adr

```
Write an Architecture Decision Record for this plan:
- Context: the forces and constraints
- Decision: what is being chosen
- Consequences: what becomes easier and what becomes harder
- Alternatives considered: and why rejected
Keep each section tight. This is a record, not an essay.
```
