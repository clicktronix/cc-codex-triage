---
description: Arm or disarm the self-verification loop. Arming immediately reviews any work already on the branch, then blocks future turn-ends with unverified code changes until a Codex review reaches APPROVE (or the round cap).
argument-hint: "on [--lens <name>] [--cap N] | off | status"
allowed-tools: Bash
disable-model-invocation: true
---

# /autoreview

Two parts: (1) **on arming, if the branch already has code changes, run the review immediately** — so existing work gets reviewed right away without you typing `/review`; (2) arms a Stop hook that blocks the end of every future turn in which the code differs from the last state this gate released, pointing Claude at the `/review` command file to follow with `--thread review-<branch>` and address blocking findings. Blocking ends when the review thread's last verdict is an **APPROVE earned inside the current cycle** (a stale APPROVE from an earlier cycle or arming does not count — the hook only parses verdicts from log content appended after the cycle's byte-offset cut), when the round cap is hit (each block consumes one of `cap` rounds, within or across turns), or on `/autoreview off`.

**The unit is a cycle, not an arming.** It opens when the code differs from the last released state and closes on an APPROVE covering the state in front of you. Because the fingerprint hashes working-tree *content*:

- **committing the fixes keeps the gate engaged** — a fix is still a difference after it is committed, where the old dirty-tree test went quiet exactly when the follow-up round was owed;
- **committing already-approved bytes costs nothing** — identical content hashes identically;
- **one APPROVE covers one state** — each release records the fingerprint the dispatch was made against, so the next edit re-engages the gate. If the code already moved after the verdict, the next cycle opens in the same turn rather than at the next one.

Runaway-safe: the cap terminates each cycle (counters numeric-validated, malformed state fails OPEN) and only a real release refills it. The hook never calls Codex — it routes you to the normal `/review` flow.

**Arming mid-change costs a round:** any non-state-dir difference from the arming fingerprint counts as unverified, WIP and editor droppings included. Gitignored files never count — a gate firing on `.env` would be unusable.

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
   # log_gen_at_arming: how many times the driver has rotated this thread's log.
   # The cut above is a byte offset into the log as it is NOW, so a later
   # rotation makes it meaningless; a changed generation tells the hook to parse
   # the whole current log instead.
   # Same grammar the driver and the hook use — a leading zero is not
   # octal-safe in shell arithmetic, so anything malformed is generation 0.
   LOG_GEN=$(cat "$STATE_DIR/$THREAD.log-gen" 2>/dev/null | tr -cd '0-9')
   case "$LOG_GEN" in ''|0*[0-9]*) LOG_GEN=0 ;; esac; LOG_GEN=${LOG_GEN:-0}
   printf 'branch=%s\nthread=%s\nlens=%s\ncap=%s\nblocks=0\nlog_bytes_at_arming=%s\nlog_gen_at_arming=%s\narmed_at=%s\nfp_at_arming=%s\n' \
     "$BRANCH" "$THREAD" "<LENS>" "<CAP>" "$LOG_BYTES" "$LOG_GEN" "$(date +%s)" "$FP" \
     | bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-state.sh" write "$STATE_DIR/autoreview.armed" || exit 1
   echo "autoreview armed for branch $BRANCH -> thread $THREAD (lens <LENS>, cap <CAP>)."
   # Is there already work to review on this branch?
   git status --porcelain -uall | grep -vF '.claude/codex-threads/' | grep -q . \
     && echo "DIRTY: existing changes present — reviewing now" \
     || echo "CLEAN: nothing to review yet; gate will engage when you make changes"
   ```

3. **`on` + DIRTY → review the existing work immediately.** Do not wait for a turn-end. Read `${CLAUDE_PLUGIN_ROOT}/commands/review.md` and follow its steps right now with `--once --thread <THREAD> --lens <LENS>` on the current changes (`--once` keeps this a SINGLE dispatch — the gate iterates across later turns via its capped blocks; a default loop here would multiply gate cost) — the file path matters: `/review` is `disable-model-invocation`, so you cannot invoke it as a command and must follow its steps from the file. Show Codex's findings, validate them against the code, and address blocking ones per the skill's fix-the-neighborhood rule. This is the part that removes the manual `/review` step. If CLEAN, skip — there is nothing to review; just confirm the gate is armed for future changes.

4. `off` — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-state.sh" remove .claude/codex-threads/autoreview.armed` (from the repo root — `cd "$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)" || exit 7` first; the guard keeps a failed resolve from touching the wrong directory) and confirm. Not a bare `rm`: the Stop hook rewrites this same file under a mutex, and an unserialized delete races a turn-end write that would put the gate back.

5. `status` — cat the armed file (or "not armed"), plus the target thread's last verdict if its log exists. Same repo-root anchoring.

6. Tell the user: existing work was just reviewed (if any); from now on the gate engages at the end of each turn whose code differs from the last released state — **including a turn that only committed** — and releases on an APPROVE covering that state, on cap, or on `off`. The hook requires the plugin's hooks to be loaded (restart or `/reload-plugins` after install).

## Notes

- Armed state: `.claude/codex-threads/autoreview.armed`. Branch-scoped — switching branches disengages it until you re-arm (or switch back).
- Fields: `branch`, `thread`, `lens`, `cap`, `blocks`, `log_bytes_at_arming`, `armed_at`, plus `fp_at_arming` (written here) and `released_fp` (written by the hook on each release). With neither fingerprint field the file is a pre-0.9 arming: dirty-tree behaviour until its first release, cycle model after it.
- Gates auto-expire 14 days after arming: the hook removes the stale armed file on the next gated turn (re-arm to continue).
- Each blocked round is a full Codex dispatch. cap defaults to 3 and bounds ONE cycle; reaching APPROVE grants a fresh budget.
- Pairs with `/autoplan` (same hook, plan-document gate).
