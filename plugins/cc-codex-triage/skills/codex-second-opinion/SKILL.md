---
name: codex-second-opinion
description: Ask OpenAI Codex CLI for one bounded second opinion when you are genuinely stuck — a fork you cannot settle from the code, an irreversible change you are about to make, or two sources in the repo that contradict each other. One dispatch, announced before it is spent. Not a review loop; for that read the /review command file.
when_to_use: Use when you have already looked and the repository does not settle the question — two designs both defensible, a migration or deletion you cannot undo, a doc and the code disagreeing, or a finding you cannot verify without something you do not have. Do not use for questions the code answers, for routine critique, or more than once on the same fork.
allowed-tools: Bash
---

# Codex second opinion

Every other command in this plugin is `disable-model-invocation` — deliberately, because each one spends real money and minutes and the user should be the one deciding to. This skill is the exception: a single bounded dispatch you may reach for on your own when you are stuck in a way the repository cannot resolve.

It is narrow on purpose. It gets one question answered. It is **not** the review loop — for that, read `${CLAUDE_PLUGIN_ROOT}/commands/review.md` and follow its steps.

## When this is the right call

All of these share one property: more reading will not settle it.

- **A fork with no local evidence.** Two designs are both defensible and the codebase does not prefer either. (If the codebase *does* prefer one, that is your answer — use it.)
- **About to do something irreversible.** A destructive migration, a deletion, a rewrite whose old version will not be recoverable.
- **The repository contradicts itself.** A doc, a comment or a test says one thing and the code does another, and which is authoritative changes what you write.
- **A finding you cannot verify.** You need a runtime trace, prod data or a file you do not have — per the skill `codex-triage` rule, say so rather than applying on faith. Codex running with `-C <repo>` may be able to reach what you cannot.

## When it is not

- **The code answers it.** Read the code. This costs minutes and money; grep costs neither.
- **You want a critique of a diff or a plan.** That is `/review` or `/plan`, and they belong to the user.
- **You already asked about this fork.** One dispatch per fork. A second means you are running a review loop without saying so — go to the user instead.
- **You are stuck on something the user can answer in one line.** Ask them. It is faster and free.

## How to run it

**1. Announce before spending.** One line, before the call, saying what you are asking and why the repo does not settle it. The user can stop you; after the dispatch they cannot.

**2. Pick the thread.**

- A feature thread already exists for this work → use it; Codex has the context and you pay less to establish it.
- Otherwise `--thread <topic-slug>` — a fresh named thread.
- Genuinely one-off, no follow-up conceivable → add `--oneshot` for an ephemeral run that leaves no state.

Never target `review-<branch>`: the `/autoreview` gate parses verdicts from that log, and an unrelated question in it is noise in the audit trail at best.

**3. Send intent, not context.** Codex is an agent — it reads files, runs `git diff`, greps and runs tests on its own. It does not have your *intent*, your *scope*, or what you have already ruled out. Send those; do not paste the codebase.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> [--oneshot] <<< "$QUESTION"
```

Prompt shape:

```
I need a second opinion on one decision. Do not review the branch; answer this.

Decision: <the fork, stated as a choice between named options>
What I already checked: <files, tests, docs — and what they did NOT settle>
What would change my mind: <the evidence that would decide it>

Give your recommendation and the evidence for it, with file:line where it is in
the repo. Say explicitly if the question is underdetermined by the code.
```

**4. Show the reply verbatim.** Do not paraphrase Codex.

**5. Treat it as a claim, not an order.** The skill `codex-triage` rule applies in full: read the cited site *and its consumers*, check for a reason the current code stands, confirm the suggested direction does not regress something. A second opinion you cannot verify is still a second opinion, not a decision.

**6. One dispatch.** If the reply does not settle it, that is information — take it to the user with both positions. Do not open a round 2.

## Exit codes

Handle these per skill `codex-triage`: 3 = dispatch failed, 4 = resume failed (**ask the user before `--new`** — never auto-reset a thread), 5 = tracked-file mutation under strict mode, 7 = not a git repo, 10 = thread busy. On any of them, report the failure honestly rather than guessing what Codex would have said.

## Verification gate

- [ ] The cost was announced before the dispatch, not after.
- [ ] The thread is not a `review-<branch>` gate thread.
- [ ] Codex's reply was shown verbatim.
- [ ] The recommendation was checked against the code before being acted on.
- [ ] Exactly one dispatch was spent.
