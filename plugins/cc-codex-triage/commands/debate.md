---
description: Compare defensible positions through a bounded debate between Claude Code and Codex, then synthesize the evidence and remaining disagreement. Available to an owning agent during an authorized task.
argument-hint: "[--rounds N] [--thread <name>] [--topic <text>] [--model <m>] [--effort <e>] <question or decision>"
allowed-tools: Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh *)
---

# /debate

Use when competing positions deserve adversarial examination. Follow
`${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/SKILL.md` for ownership and recovery.
The owner may initiate this within an authorized task and budget without a new
permission question. Repository context is optional.

1. Parse `--rounds N` as a total dispatch ceiling (default 5, maximum 15), including
   any Codex synthesis call. It is not a target. Use `--thread` when supplied or
   `debate-<short-topic-slug>`; resume only the same unresolved question. Pass
   `--topic` if supplied to label the conversation on creation, and `--model` /
   `--effort` if supplied on every dispatch of the debate, rebuttals included.
2. Establish your position and its evidence before dispatch. Ask Codex for its
   strongest independent position, agreeing or disagreeing as the evidence warrants.
   Include the question, constraints and sources unavailable in its context. Request
   relevant file/line or source citations, and changes of position tied to evidence.
   Both participants should use read-only tools; no implementation or issue creation.
3. Keep debate separate from a required-review claim:

   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh" advisory-check "$THREAD" || exit $?
   "${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" --read-only --search \
     ${MODEL:+--model "$MODEL"} ${EFFORT:+--effort "$EFFORT"} <<< "$OPENING"
   ```

   Use the same route for rebuttals. Follow the shared long-dispatch handoff; never
   repeat an in-flight turn. Check claims, add evidence and reconsider your position
   when warranted. Stop when a round adds no useful evidence or the question is settled.
4. Synthesize agreement, remaining disagreement, what changed either position, and a
   recommendation. If another Codex synthesis call would exceed the ceiling, synthesize
   locally from the existing exchange. Never manufacture consensus or an approval marker.
   The owner resolves routine technical choices and continues the task; ask the user
   only for a missing product decision, access or waiver.

For an agent-initiated debate, show the reason for it and the useful conclusion;
retain the complete exchange in the thread log. Show labelled exchanges in full when
the user requests to watch the debate. Avoid flooding the main run with repeated arguments.

Each dispatch uses the supplied `--model` / `--effort`, else Codex's configured ones, and
may incur cost; the ceiling bounds calls, not dollars. Use available usage/pricing evidence and state an unknown price as
unknown. Honor an already-authorized budget; request expansion only when necessary.
