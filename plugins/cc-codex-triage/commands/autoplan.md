---
description: Arm or disarm the plan-verification gate — when armed, Claude Code cannot finish a turn that changed plan documents until the updated plan has been stress-tested via /plan at least once.
argument-hint: "on [--lens <name>] [--cap N] | off | status"
allowed-tools: Bash
disable-model-invocation: true
---

# /autoplan

Arms a Stop hook that blocks the end of any turn in which plan documents (`docs/plans/**`, `docs/PLANS/**`) changed without a `/plan` stress-test since arming, instructing Claude to run `/plan --thread plan-<branch>` first. Blocking ends after one completed `/plan` round, on the round cap, or on `/autoplan off`.

Unlike `/autoreview`, the gate does NOT parse the plan verdict (sound/not-sound is prose) — it guarantees a stress-test *happened*, and the verdict is visible in the transcript for you to act on. Re-arm to force another round after major plan revisions.

## Steps

1. Parse `$ARGUMENTS`: `on` (default), `off`, or `status`. For `on`, optional `--lens <name>` (default `stress-test`) and `--cap N` (default 2).

2. `on` — write the armed file, snapshotting the thread's current round count:

   ```bash
   STATE_DIR=".claude/codex-threads"; mkdir -p "$STATE_DIR"
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   THREAD="plan-$(echo "$BRANCH" | tr '/' '-')"
   ROUNDS=$(cat "$STATE_DIR/$THREAD.rounds" 2>/dev/null || echo 0)
   printf 'branch=%s\nthread=%s\nlens=%s\ncap=%s\nblocks=0\nrounds_at_arming=%s\n' \
     "$BRANCH" "$THREAD" "<LENS>" "<CAP>" "$ROUNDS" > "$STATE_DIR/autoplan.armed"
   echo "autoplan armed for branch $BRANCH -> thread $THREAD (lens <LENS>, cap <CAP>)."
   ```

3. `off` — `rm -f .claude/codex-threads/autoplan.armed` and confirm.

4. `status` — cat the armed file (or "not armed").

5. Tell the user how it releases: one `/plan` round on the target thread since arming, cap, or `off`. Requires plugin hooks loaded (restart or `/reload-plugins` after install).

## Notes

- Armed state: `.claude/codex-threads/autoplan.armed`. Branch-scoped.
- Plan-doc detection covers `docs/plans/` and `docs/PLANS/` (the two conventions seen in real repos). Other layouts: keep plans in one of these, or use `/plan` manually.
- Pairs with `/autoreview` (same hook, code gate).
