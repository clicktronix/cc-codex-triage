---
description: Arm or disarm the self-verification loop — when armed, Claude Code cannot finish a turn with unverified code changes until a Codex review of them reaches APPROVE (or the round cap).
argument-hint: "on [--lens <name>] [--cap N] | off | status"
allowed-tools: Bash
disable-model-invocation: true
---

# /autoreview

Arms a Stop hook that blocks the end of every turn while there are uncommitted/unreviewed code changes on the current branch, instructing Claude to run `/review --thread review-<branch>` and address blocking findings. Blocking ends when the review thread's last verdict is **APPROVE**, when the round cap is hit (each block consumes one of `cap` rounds, within or across turns), or on `/autoreview off`.

Runaway-safe: the per-arming round cap is the hard terminator (counters are numeric-validated; malformed state fails OPEN), the APPROVE gate is the success release, and branch/dirty scoping keeps the gate out of unrelated work. The hook itself never calls Codex — it only routes you to the normal `/review` flow, so the worst case costs `cap` review dispatches per arming.

**Arm on a clean tree.** The gate treats ANY non-state-dir change as unverified — pre-existing WIP, untracked `.env`, editor droppings included. Arming on a dirty tree means the very next turn blocks, even a pure Q&A turn. Commit/stash first, or expect the first block immediately.

## Steps

1. Parse `$ARGUMENTS`: first token is `on` (default if flags/empty follow), `off`, or `status`. For `on`, optional `--lens <name>` (default `correctness`) and `--cap N` (default 3, max 5).

2. `on` — write the armed file (per-branch thread per the skill's one-task-one-thread rule):

   ```bash
   STATE_DIR=".claude/codex-threads"; mkdir -p "$STATE_DIR"
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   THREAD="review-$(echo "$BRANCH" | tr '/' '-')"
   printf 'branch=%s\nthread=%s\nlens=%s\ncap=%s\nblocks=0\n' \
     "$BRANCH" "$THREAD" "<LENS>" "<CAP>" > "$STATE_DIR/autoreview.armed"
   echo "autoreview armed for branch $BRANCH -> thread $THREAD (lens <LENS>, cap <CAP>)."
   ```

3. `off` — `rm -f .claude/codex-threads/autoreview.armed` and confirm.

4. `status` — cat the armed file (or "not armed"), plus the target thread's last verdict if its log exists.

5. Tell the user: the gate engages at the end of each turn with code changes; it releases on APPROVE, on cap, or on `off`. The hook requires the plugin's hooks to be loaded (restart or `/reload-plugins` after install).

## Notes

- Armed state: `.claude/codex-threads/autoreview.armed`. Branch-scoped — switching branches disengages it until you re-arm (or switch back).
- Each blocked round is a full Codex dispatch when you run `/review` — cap defaults to 3 to bound cost.
- Pairs with `/autoplan` (same hook, plan-document gate).
