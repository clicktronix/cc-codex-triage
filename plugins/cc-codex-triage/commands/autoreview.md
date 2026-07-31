---
description: Arm or disarm the self-verification loop. Arming immediately reviews any work already on the branch, then blocks future turn-ends with unverified code changes until a Codex review reaches APPROVE (or the round cap).
argument-hint: "on [--lens <name>] [--cap N] | off | status"
allowed-tools: Bash
disable-model-invocation: true
---

# /autoreview

Two parts: (1) **on arming, if the branch already has code changes, run the review immediately** — so existing work gets reviewed right away without you typing `/review`; (2) arms a Stop hook that blocks the end of every future turn in which the code differs from the last state this gate released, pointing Claude at the `/review` command file to follow with `--thread review-<branch>` and address blocking findings. Blocking ends when the review thread's last verdict is an **APPROVE earned inside the current cycle** (a stale APPROVE from an earlier cycle or arming does not count — the hook only parses verdicts from log content appended after the cycle's byte-offset cut), when the round cap is hit (each block consumes one of `cap` rounds, within or across turns), or on `/autoreview off`.

**The unit is a cycle, not an arming.** A cycle opens when the code moves away from the last released state and closes on an APPROVE that covers the state actually in front of you. Then a new cycle can open. Two consequences worth knowing:

- **Committing the fixes does not end the round.** The gate compares a fingerprint that includes `HEAD`, so a commit is a change, not a disappearance. Under the old dirty-tree test, committing made the tree clean and the turn was allowed to finish with the thread's last verdict still `REQUEST_CHANGES` — the follow-up round simply never happened.
- **One APPROVE does not cover later work.** Each release records the fingerprint it approved, so the next edit re-engages the gate instead of coasting on a verdict that was true an hour ago.

Runaway-safe: the round cap is the hard terminator **per cycle** (counters are numeric-validated; malformed state fails OPEN), the APPROVE gate is the success release, and branch scoping keeps the gate out of unrelated work. Only a real release refills the budget, so a cycle that never earns an APPROVE still stops at `cap` blocks. The hook itself never calls Codex — it only routes you to the normal `/review` flow.

**Arming on a dirty tree is fine now, but it costs a round.** The gate treats any non-state-dir difference from the arming fingerprint as unverified — pre-existing WIP, untracked `.env`, editor droppings included — so arming mid-change means the next turn blocks. Commit or stash first if you want the first block to be about *your* work.

**Known blind spot:** the fingerprint sees untracked files by path *and content*, tracked files by diff, and commits by `HEAD`. It does not see changes to files git ignores. That is deliberate — a gate that fired on `.env` or build output would be unusable.

## Steps

1. Parse `$ARGUMENTS`: first token is `on` (default if flags/empty follow), `off`, or `status`. For `on`, optional `--lens <name>` (default `correctness`) and `--cap N` (default 3, max 5).

2. `on` — write the armed file (per-branch thread per the skill's one-task-one-thread rule), and capture whether the branch is already dirty:

   ```bash
   # Anchor to the repo root — the hook and driver read state there, and a
   # drifted cwd would arm a gate the hook never sees.
   cd "$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)" || exit 7   # resolves a subdir candidate UP to the repo root — state lives at the ROOT; HARD-FAIL outside a repo (a fail-soft cd would mutate state in the wrong directory)
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
   # fp_at_arming: the code state the gate starts from. The hook fires while
   # the code differs from this, and re-baselines it on every release — which
   # is what makes COMMITTING the fixes keep the gate engaged (a bare dirty-
   # tree test goes quiet at exactly the moment the next round is still owed).
   # Written by the shared script the hook itself calls, never hand-rolled.
   FP=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-fingerprint.sh")
   # armed_at: the hook auto-expires a gate armed more than 14 days ago.
   printf 'branch=%s\nthread=%s\nlens=%s\ncap=%s\nblocks=0\nlog_bytes_at_arming=%s\narmed_at=%s\nfp_at_arming=%s\n' \
     "$BRANCH" "$THREAD" "<LENS>" "<CAP>" "$LOG_BYTES" "$(date +%s)" "$FP" > "$STATE_DIR/autoreview.armed"
   echo "autoreview armed for branch $BRANCH -> thread $THREAD (lens <LENS>, cap <CAP>)."
   # Is there already work to review on this branch?
   git status --porcelain -uall | grep -vF '.claude/codex-threads/' | grep -q . \
     && echo "DIRTY: existing changes present — reviewing now" \
     || echo "CLEAN: nothing to review yet; gate will engage when you make changes"
   ```

3. **`on` + DIRTY → review the existing work immediately.** Do not wait for a turn-end. Read `${CLAUDE_PLUGIN_ROOT}/commands/review.md` and follow its steps right now with `--once --thread <THREAD> --lens <LENS>` on the current changes (`--once` keeps this a SINGLE dispatch — the gate iterates across later turns via its capped blocks; a default loop here would multiply gate cost) — the file path matters: `/review` is `disable-model-invocation`, so you cannot invoke it as a command and must follow its steps from the file. Show Codex's findings, validate them against the code, and address blocking ones per the skill's fix-the-neighborhood rule. This is the part that removes the manual `/review` step. If CLEAN, skip — there is nothing to review; just confirm the gate is armed for future changes.

4. `off` — `rm -f .claude/codex-threads/autoreview.armed` (from the repo root — `cd "$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)" || exit 7` first; the guard keeps a failed resolve from deleting files in the wrong directory) and confirm.

5. `status` — cat the armed file (or "not armed"), plus the target thread's last verdict if its log exists. Same repo-root anchoring.

6. Tell the user: existing work was just reviewed (if any); from now on the gate engages at the end of each turn whose code differs from the last released state — **including a turn that only committed** — and releases on an APPROVE covering that state, on cap, or on `off`. The hook requires the plugin's hooks to be loaded (restart or `/reload-plugins` after install).

## Notes

- Armed state: `.claude/codex-threads/autoreview.armed`. Branch-scoped — switching branches disengages it until you re-arm (or switch back).
- Fields: `branch`, `thread`, `lens`, `cap`, `blocks`, `log_bytes_at_arming`, `armed_at`, `fp_at_arming` (0.9+, written here) and `released_fp` (0.9+, written by the hook on each release). An armed file with neither fingerprint field is a pre-0.9 arming: it keeps the old dirty-tree behaviour **until its first release**, at which point the hook writes `released_fp` and it follows the cycle model from then on. So an upgrade never changes a gate mid-cycle, and an old gate still picks up the fix instead of carrying the holes until you happen to re-arm.
- Gates auto-expire 14 days after arming: the hook removes the stale armed file on the next gated turn (re-arm to continue).
- Each blocked round is a full Codex dispatch when you run `/review` — cap defaults to 3 and bounds ONE cycle; a cycle that reaches APPROVE gets a fresh budget for the next one.
- Pairs with `/autoplan` (same hook, plan-document gate).
