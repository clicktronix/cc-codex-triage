---
description: Arm or disarm the plan-verification gate. Arming immediately stress-tests any plan document already changed on the branch, then blocks future turn-ends that change plan docs until the plan thread has seen a post-arming dispatch (normally your /plan stress-test).
argument-hint: "on [--lens <name>] [--cap N] | off | status"
allowed-tools: Bash
disable-model-invocation: true
---

# /autoplan

Arms a Stop hook that blocks the end of any turn in which plan documents (`docs/plans/**`, `docs/PLANS/**`) differ from the last state this gate released, pointing Claude at the `/plan` command file to follow with `--thread plan-<branch>`. Blocking ends after one dispatch on that thread within the current cycle (normally your `/plan` round — see the caveat below), on the round cap, or on `/autoplan off`.

**The unit is a cycle, not an arming.** Each release records the plan state it covered and advances the log baseline, so the *next* plan edit needs its own dispatch. That matters more here than for code: a plan document is untracked for its whole first life, so without hashing untracked content a plan could be rewritten end to end after one release and never re-engage the gate.

Unlike `/autoreview`, the gate does NOT parse the plan verdict (sound/not-sound is prose). The release signal is the thread log growing since arming — which any dispatch to the plan thread produces, including a `/reply plan-<branch>` or `/thread plan-<branch>`. So strictly the gate guarantees *a dispatch to the plan thread happened since arming*; it is a stress-test guarantee only as long as you route actual `/plan` runs (not chatter) to that thread, which the per-task thread convention already does. The verdict is visible in the transcript for you to act on. Re-arm to force another round after major plan revisions.

## Steps

1. Parse `$ARGUMENTS`: `on` (default), `off`, or `status`. For `on`, optional `--lens <name>` (default `stress-test`) and `--cap N` (default 2).

2. `on` — write the armed file, snapshotting the thread log's current byte size:

   ```bash
   # Anchor to the repo root — the hook and driver read state there, and a
   # drifted cwd would arm a gate the hook never sees.
   cd "$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)" || exit 7   # resolves a subdir candidate UP to the repo root — state lives at the ROOT; HARD-FAIL outside a repo (a fail-soft cd would mutate state in the wrong directory)
   STATE_DIR=".claude/codex-threads"; mkdir -p "$STATE_DIR"
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   # Slug rule shared with the hook: every char outside the driver's
   # [a-zA-Z0-9_.-] alphabet becomes '-' (git allows +, #, @ ... in branches).
   THREAD="plan-$(printf '%s' "$BRANCH" | tr -c 'a-zA-Z0-9_.-' '-')"
   # Snapshot the thread log's byte size: the hook treats "log size changed
   # since arming" as proof of a post-arming dispatch on the plan thread
   # (normally your /plan round). The log, unlike .rounds, is not reset by
   # /thread-new — a bare reset cannot fake a dispatch.
   LOG_BYTES=$(wc -c 2>/dev/null < "$STATE_DIR/$THREAD.log" | tr -d ' '); LOG_BYTES=${LOG_BYTES:-0}
   # Plan-doc locations honor CC_CODEX_PLAN_PATHS (space-separated pathspecs;
   # default = the two conventional dirs). The hook reads the SAME variable.
   PLAN_PATHS="${CC_CODEX_PLAN_PATHS:-docs/plans docs/PLANS}"
   # fp_at_arming: the plan state the gate starts from, scoped to those paths.
   # The hook fires while the plan docs differ from it and re-baselines it on
   # every release, so the NEXT plan edit needs its own dispatch instead of
   # coasting on the one that released the last cycle.
   # set -f: pass the pathspecs to the script unexpanded.
   FP=$( set -f; bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-fingerprint.sh" $PLAN_PATHS )
   # armed_at: the hook auto-expires a gate armed more than 14 days ago.
   printf 'branch=%s\nthread=%s\nlens=%s\ncap=%s\nblocks=0\nlog_bytes_at_arming=%s\narmed_at=%s\nfp_at_arming=%s\n' \
     "$BRANCH" "$THREAD" "<LENS>" "<CAP>" "$LOG_BYTES" "$(date +%s)" "$FP" \
     | bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-state.sh" write "$STATE_DIR/autoplan.armed" || exit 1
   echo "autoplan armed for branch $BRANCH -> thread $THREAD (lens <LENS>, cap <CAP>)."
   # Already-changed plan docs to stress-test now?
   # set -f: pass the pathspecs to git unexpanded (no shell globbing first).
   ( set -f; git status --porcelain -uall -- $PLAN_PATHS | grep -q . ) \
     && echo "PLANS DIRTY: stress-testing now" || echo "no changed plan docs yet; gate armed for future"
   ```

3. **`on` + changed plan docs → stress-test immediately.** Read `${CLAUDE_PLUGIN_ROOT}/commands/plan.md` and follow its steps now with `--once --thread <THREAD> --lens <LENS>` on the updated plan (`--once` keeps this a SINGLE dispatch — the gate iterates across later turns via its capped blocks) — the file path matters: `/plan` is `disable-model-invocation`, so you cannot invoke it as a command and must follow its steps from the file. Show Codex's verdict, address blocking objections. If no plan docs changed, skip — just confirm the gate is armed.

4. `off` — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/gate-state.sh" remove .claude/codex-threads/autoplan.armed` (from the repo root — `cd "$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)" || exit 7` first; the guard keeps a failed resolve from touching the wrong directory) and confirm. Not a bare `rm`: the Stop hook rewrites this same file under a mutex, and an unserialized delete races a turn-end write that would put the gate back.

5. `status` — cat the armed file (or "not armed"). Same repo-root anchoring.

6. Tell the user how it releases: one dispatch to the target plan thread since arming (normally your `/plan` round — see the caveat above), cap, or `off`. Requires plugin hooks loaded (restart or `/reload-plugins` after install).

## Notes

- Armed state: `.claude/codex-threads/autoplan.armed`. Branch-scoped.
- Fields mirror `/autoreview`, including `fp_at_arming` (0.9+, written here) and `released_fp` (0.9+, written by the hook). An armed file with neither is a pre-0.9 arming: dirty-tree behaviour until its first release, cycle model after it.
- Gates auto-expire 14 days after arming: the hook removes the stale armed file on the next gated turn (re-arm to continue).
- Plan-doc detection covers `docs/plans/` and `docs/PLANS/` by default. For other layouts, set `CC_CODEX_PLAN_PATHS` (space-separated pathspecs, e.g. `CC_CODEX_PLAN_PATHS="docs/rfcs planning"`) in your environment — the hook and the arming check both honor it. Or use `/plan` manually.
- Pairs with `/autoreview` (same hook, code gate).
