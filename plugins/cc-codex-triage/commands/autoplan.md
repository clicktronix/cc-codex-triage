---
description: Arm or disarm the plan-verification gate. Arming immediately stress-tests any plan document already changed on the branch, then blocks future turn-ends that change plan docs until they have been stress-tested via /plan.
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
   # Already-changed plan docs to stress-test now?
   git status --porcelain -uall -- 'docs/plans' 'docs/PLANS' | grep -q . \
     && echo "PLANS DIRTY: stress-testing now" || echo "no changed plan docs yet; gate armed for future"
   ```

3. **`on` + changed plan docs → stress-test immediately.** Run `/plan --thread <THREAD> --lens <LENS>` now on the updated plan (per the `/plan` command's steps), show Codex's verdict, address blocking objections. If no plan docs changed, skip — just confirm the gate is armed.

4. `off` — `rm -f .claude/codex-threads/autoplan.armed` and confirm.

5. `status` — cat the armed file (or "not armed").

6. Tell the user how it releases: one `/plan` round on the target thread since arming, cap, or `off`. Requires plugin hooks loaded (restart or `/reload-plugins` after install).

## Notes

- Armed state: `.claude/codex-threads/autoplan.armed`. Branch-scoped.
- Plan-doc detection covers `docs/plans/` and `docs/PLANS/` (the two conventions seen in real repos). Other layouts: keep plans in one of these, or use `/plan` manually.
- Pairs with `/autoreview` (same hook, code gate).
