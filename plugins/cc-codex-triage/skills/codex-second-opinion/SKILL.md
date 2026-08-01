---
name: codex-second-opinion
description: Ask OpenAI Codex CLI for one bounded second opinion when you are genuinely stuck — a fork you cannot settle from the code, an irreversible change you are about to make, or two sources in the repo that contradict each other. One dispatch, announced before it is spent. Not a review loop; for that read the /review command file.
when_to_use: Use when you have already looked and the repository does not settle the question — two designs both defensible, a migration or deletion you cannot undo, a doc and the code disagreeing, or a finding you cannot verify without something you do not have. Do not use for questions the code answers, for routine critique, or more than once on the same fork.
allowed-tools: Bash
---

# Codex second opinion

Every slash command in this plugin is `disable-model-invocation`, because each spends real money and minutes and the user should decide. This skill is the exception: **one** bounded dispatch you may reach for yourself. It is not the review loop — for that, read `${CLAUDE_PLUGIN_ROOT}/commands/review.md` and follow its steps.

## Use it when

All of these share one property: more reading will not settle it.

- **A fork with no local evidence** — two designs both defensible, the codebase preferring neither. (If it does prefer one, that is your answer.)
- **An irreversible change** — a destructive migration, a deletion, a rewrite whose old version will not be recoverable.
- **The repository contradicts itself** — a doc, comment or test says one thing and the code another, and which is authoritative changes what you write.
- **A finding you cannot verify** — you need a runtime trace, prod data, a file you do not have. Codex runs with `-C <repo>` and may reach what you cannot.

## Not when

- **The code answers it.** Grep is free; this is not.
- **You want a critique of a diff or plan.** That is `/review` or `/plan`, and they belong to the user.
- **You already asked about this fork.** One dispatch per fork — a second is a review loop you did not declare. Go to the user.
- **The user could answer in one line.** Ask them.

## How

**1. Announce before spending.** One line saying what you are asking and why the repo does not settle it. The user can stop you before the dispatch, not after.

**2. Pick the thread — look first.** Reusing a thread that already holds the context is cheaper and better-informed than opening a new one, so list what exists (a local read, no dispatch):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/thread-index.sh"
```

Reuse a thread whose topic covers this question. Otherwise open one with `--thread <slug> --topic "<what it is about>"`, so the next agent can make the same judgement. `--oneshot` for a genuinely one-off question. **Never `review-<branch>`** — the `/autoreview` gate parses verdicts from that log. A `[busy]` thread has a dispatch in flight and would refuse yours (exit 10).

**3. Send intent, not context.** Codex reads files, runs `git diff`, greps and runs tests itself. What it lacks is your intent, your scope, and what you have already ruled out.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> [--topic "<text>"] [--oneshot] <<< "$QUESTION"
```

```
I need a second opinion on one decision. Do not review the branch; answer this.

Decision: <the fork, as a choice between named options>
What I already checked: <files, tests, docs — and what they did NOT settle>
What would change my mind: <the evidence that would decide it>

Give your recommendation and the evidence for it, with file:line where it is in
the repo. Say explicitly if the question is underdetermined by the code.
```

**4. Show the reply verbatim.**

**5. Treat it as a claim, not an order.** The skill `codex-triage` validation rule applies in full: read the cited site and its consumers, check for a reason the current code stands, confirm the suggested direction does not regress something.

**6. One dispatch.** If the reply does not settle it, take both positions to the user. Do not open a round 2.

Exit codes per skill `codex-triage`: 3 = dispatch failed, 4 = resume failed (**ask before `--new`**), 5 = tracked-file mutation, 7 = not a git repo, 10 = thread busy. Report failures honestly rather than guessing what Codex would have said.

## Verification gate

- [ ] Cost announced before the dispatch.
- [ ] Existing threads were listed before opening a new one.
- [ ] Thread is not a `review-<branch>` gate thread; a new one carries a `--topic`.
- [ ] Codex's reply shown verbatim.
- [ ] The recommendation checked against the code before acting on it.
- [ ] Exactly one dispatch spent.
