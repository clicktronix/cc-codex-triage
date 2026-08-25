# Review and plan lenses

Read this file only for `/review` or `/plan`. Pick one focus line and append the
matching output contract. Codex gathers repository context itself.

## Review focus

- `correctness` (default): review logic, invariants, boundary and error states,
  scope gaps, and tests for changed behavior.
- `security`: review validation, authorization, injection, secret exposure,
  data integrity, races, and unsafe errors; ignore unrelated style.
- `performance`: report only plausible material costs and name the data size or
  request-rate condition that triggers them.
- `architecture`: review ownership, dependency direction, abstraction leaks,
  test seams, and consistency with the repository's documented design.
- `ux`: review loading, empty and error states, responsive layout, keyboard and
  focus behavior, accessibility, validation feedback, and hydration issues.
- `quick`: report only obvious blockers visible in a short smoke review.

For every review lens, add:

```text
Report findings only. Cite file:line and explain impact and the smallest fix.
Do not edit files. Search immediate sibling sites when one instance reveals a
shared problem class. On follow-up, report changed or new findings instead of
repeating resolved prose. End with exactly one bare final verdict line:
APPROVE, REQUEST_CHANGES, or COMMENT. Use REQUEST_CHANGES only for a blocking
finding. Honour AGENTS.md.
```

## Plan focus

- `stress-test` (default): find missing steps, dependencies, sequencing risks,
  unstated assumptions, irreversible operations, and rollback gaps.
- `pre-mortem`: assume the plan failed in production; identify the likely cause,
  missed warning, and the few changes that most reduce the risk.
- `devils-advocate`: steelman doing nothing and the strongest case against the
  proposed approach, then say whether the objections are decisive.
- `alternatives`: compare two or three approaches by their main trade-off and
  when each would beat the proposal.
- `adr`: write a compact Context, Decision, Consequences, and Alternatives
  record.

For every plan lens, add:

```text
Enumerate all instances of a discovered gap class in this round. End with
exactly one bare final verdict line: APPROVE, REQUEST_CHANGES, or COMMENT.
APPROVE means executable as written; REQUEST_CHANGES means a blocking gap
remains; COMMENT means only optional improvements.
```
