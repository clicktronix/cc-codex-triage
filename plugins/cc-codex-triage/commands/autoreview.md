---
description: Arm or disarm the self-verification loop. Arming immediately reviews any work already on the branch, then blocks future turn-ends with unverified code changes until a Codex review reaches APPROVE (or the round cap).
argument-hint: "on [--lens <name>] [--cap N] | off | status"
allowed-tools: Bash
disable-model-invocation: true
---

# /autoreview

Two parts: (1) **on arming, if the branch already has code changes, run the review immediately** — so existing work gets reviewed right away without you typing `/review`; (2) arms a Stop hook that blocks the end of every future turn while there are uncommitted/unreviewed code changes on the current branch, pointing Claude at the `/review` command file to follow with `--thread review-<branch>` and address blocking findings. Blocking ends when the review thread's last verdict is an **APPROVE earned after arming** (a stale APPROVE from a previous arming does not count — the hook only parses verdicts from log content appended after an arming-time byte-offset snapshot), when the round cap is hit (each block consumes one of `cap` rounds, within or across turns), or on `/autoreview off`.

Runaway-safe: the per-arming round cap is the hard terminator (counters are numeric-validated; malformed state fails OPEN), the APPROVE gate is the success release, and branch/dirty scoping keeps the gate out of unrelated work. The hook itself never calls Codex — it only routes you to the normal `/review` flow, so the worst case costs `cap` review dispatches per arming.

**Arm on a clean tree.** The gate treats ANY non-state-dir change as unverified — pre-existing WIP, untracked `.env`, editor droppings included. Arming on a dirty tree means the very next turn blocks, even a pure Q&A turn. Commit/stash first, or expect the first block immediately.

## Steps

1. Parse `$ARGUMENTS`: first token is `on` (default if flags/empty follow), `off`, or `status`. For `on`, optional `--lens <name>` (default `correctness`) and `--cap N` (default 3, max 5).

2. `on` — write the armed file (per-branch thread per the skill's one-task-one-thread rule), and capture whether the branch is already dirty:

   ```bash
   # Anchor to the repo root — the hook and driver read state there, and a
   # drifted cwd would arm a gate the hook never sees.
   cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
   STATE_DIR=".claude/codex-threads"; mkdir -p "$STATE_DIR"
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   # Slug rule shared with the hook: every char outside the driver's
   # [a-zA-Z0-9_.-] alphabet becomes '-' (git allows +, #, @ ... in branches).
   THREAD="review-$(printf '%s' "$BRANCH" | tr -c 'a-zA-Z0-9_.-' '-')"
   # Snapshot the thread log's byte size: the hook accepts an APPROVE only if
   # it was appended to the log AFTER this arming — a stale APPROVE from a
   # previous arming can never release the gate. (The log, unlike .rounds, is
   # not reset by /thread-new, so the snapshot cannot be faked or collided.)
   LOG_BYTES=$(wc -c 2>/dev/null < "$STATE_DIR/$THREAD.log" | tr -d ' '); LOG_BYTES=${LOG_BYTES:-0}
   printf 'branch=%s\nthread=%s\nlens=%s\ncap=%s\nblocks=0\nlog_bytes_at_arming=%s\n' \
     "$BRANCH" "$THREAD" "<LENS>" "<CAP>" "$LOG_BYTES" > "$STATE_DIR/autoreview.armed"
   echo "autoreview armed for branch $BRANCH -> thread $THREAD (lens <LENS>, cap <CAP>)."
   # Is there already work to review on this branch?
   git status --porcelain -uall | grep -vF '.claude/codex-threads/' | grep -q . \
     && echo "DIRTY: existing changes present — reviewing now" \
     || echo "CLEAN: nothing to review yet; gate will engage when you make changes"
   ```

3. **`on` + DIRTY → review the existing work immediately.** Do not wait for a turn-end. Read `${CLAUDE_PLUGIN_ROOT}/commands/review.md` and follow its steps right now with `--thread <THREAD> --lens <LENS>` on the current changes (round header, lens contract, verbatim output) — the file path matters: `/review` is `disable-model-invocation`, so you cannot invoke it as a command and must follow its steps from the file. Show Codex's findings, validate them against the code, and address blocking ones per the skill's fix-the-neighborhood rule. This is the part that removes the manual `/review` step. If CLEAN, skip — there is nothing to review; just confirm the gate is armed for future changes.

4. `off` — `rm -f .claude/codex-threads/autoreview.armed` (from the repo root — `cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"` first) and confirm.

5. `status` — cat the armed file (or "not armed"), plus the target thread's last verdict if its log exists. Same repo-root anchoring.

6. Tell the user: existing work was just reviewed (if any); from now on the gate engages at the end of each turn with code changes and releases on APPROVE, on cap, or on `off`. The hook requires the plugin's hooks to be loaded (restart or `/reload-plugins` after install).

## Notes

- Armed state: `.claude/codex-threads/autoreview.armed`. Branch-scoped — switching branches disengages it until you re-arm (or switch back).
- Each blocked round is a full Codex dispatch when you run `/review` — cap defaults to 3 to bound cost.
- Pairs with `/autoplan` (same hook, plan-document gate).
