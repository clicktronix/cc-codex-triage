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
shared problem class. End with exactly one bare final verdict line:
APPROVE, REQUEST_CHANGES, or COMMENT.
A finding is blocking only when it breaks an acceptance criterion of the spec or a
rule of the repository, or is a defect with a concrete failure scenario (input or
state -> wrong result). Wording, style, naming and hardening beyond the spec are
COMMENT, never REQUEST_CHANGES. REQUEST_CHANGES lists every blocking finding with
file:line.
On follow-up rounds, first re-check the earlier findings, then review the change
since the previous candidate. A new blocking finding outside that change needs a
P0/P1 failure scenario; otherwise it is a COMMENT. Do not repeat resolved prose.
Honour applicable AGENTS.md/CLAUDE.md, their imports and scoped rules. Check the
spec and affected consumers across file/repository boundaries; severity does not
decide scope. Reuse the supplied test evidence. You may run one targeted test when
a claim depends on it; never run the full suite, e2e, builds or containers — name
the check and what it would decide, and the owner runs it. Do not create issues,
edit, or delegate workers.
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
Enumerate all instances of a discovered gap class in this round. A gap is blocking
only when the plan cannot be executed as written or would break the agreed outcome;
safeguards beyond the spec's scope (extra hardening, production-scale concerns the
spec does not claim) are COMMENT with their cost stated, not REQUEST_CHANGES.
End with exactly one bare final verdict line: APPROVE, REQUEST_CHANGES, or COMMENT.
APPROVE means executable as written; REQUEST_CHANGES means a blocking gap
remains; COMMENT means only optional improvements.
```
