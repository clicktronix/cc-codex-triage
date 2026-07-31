#!/usr/bin/env bash
# Regression suite for hooks/stop-hook.sh. No Codex needed — synthetic state.
# Usage: bash tests/hook-regression.sh   (exit 0 = all pass)
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/plugins/cc-codex-triage/hooks/stop-hook.sh"
[[ -f "$HOOK" ]] || { echo "hook not found: $HOOK"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cc-hook-test.XXXXXX")"
ERR="$(mktemp "${TMPDIR:-/tmp}/cc-hook-err.XXXXXX")"   # OUTSIDE the test repo — an err file inside would dirty the tree
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T" "$ERR"' EXIT
cd "$T"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

DEFAULT_INPUT='{"hook_event_name":"Stop"}'
OUT=""; RC=0
run_hook() { OUT="$(printf '%s' "${1:-$DEFAULT_INPUT}" | bash "$HOOK" 2>"$ERR")"; RC=$?; }

# Fail-open contract has TWO halves: never block wrongly AND never exit
# non-zero — both are asserted on every run.
expect_allow() { run_hook "${2:-}"; [[ "$RC" -eq 0 && -z "$OUT" ]] && ok "$1" || bad "$1 (rc=$RC out: ${OUT:-empty})"; }
expect_block() { run_hook "${2:-}"; [[ "$RC" -eq 0 && "$OUT" == '{"decision":"block"'* ]] && ok "$1" || bad "$1 (rc=$RC got: ${OUT:-empty})"; }
expect_valid_json() { run_hook "${2:-}"; if [[ "$RC" -ne 0 ]]; then bad "$1 (rc=$RC)"; elif command -v jq >/dev/null; then printf '%s' "$OUT" | jq empty 2>/dev/null && ok "$1" || bad "$1 (invalid json: $OUT)"; else ok "$1 (jq absent, skipped strict check)"; fi; }

SD=.claude/codex-threads
arm_review() { # branch thread cap blocks [log_bytes_at_arming] [lens]
  mkdir -p "$SD"
  printf 'branch=%s\nthread=%s\nlens=%s\ncap=%s\nblocks=%s\nlog_bytes_at_arming=%s\n' \
    "$1" "$2" "${6:-correctness}" "$3" "$4" "${5:-0}" > "$SD/autoreview.armed"
}
arm_plan() { # branch thread cap blocks [log_bytes_at_arming]
  mkdir -p "$SD"
  printf 'branch=%s\nthread=%s\nlens=stress-test\ncap=%s\nblocks=%s\nlog_bytes_at_arming=%s\n' \
    "$1" "$2" "$3" "$4" "${5:-0}" > "$SD/autoplan.armed"
}
logsize() { wc -c 2>/dev/null < "$1" | tr -d ' '; }

echo "== outside any git repo, no state dir =="
expect_allow "no state dir, no repo -> allow"

echo "== unborn HEAD (git init, no commits) =="
git init -q -b main . && git config user.email t@t.t && git config user.name t
mkdir -p "$SD"
expect_allow "unborn HEAD allows"

echo "== baseline repo =="
echo x > f.txt && git add f.txt && git commit -qm init

echo "== not armed =="
expect_allow "state dir, nothing armed"

echo "== armed + clean tree =="
arm_review main review-main 3 0
expect_allow "armed but clean"

echo "== armed + dirty -> block, counter increments =="
echo dirty >> f.txt
expect_block "armed+dirty blocks"
[[ "$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")" == "1" ]] && ok "blocks=1 persisted" || bad "blocks not incremented"

echo "== block reason points at the command FILE (commands are disable-model-invocation) =="
printf '%s' "$OUT" | grep -q 'commands/review.md' && ok "reason carries review.md path" || bad "reason lacks command file path (got: $OUT)"

echo "== stop_hook_active does NOT unconditionally allow (until-APPROVE contract) =="
expect_block "blocks again under stop_hook_active" '{"hook_event_name":"Stop","stop_hook_active":true}'

echo "== cap is the hard terminator =="
arm_review main review-main 2 2
expect_allow "cap reached allows"
grep -q "round cap (2) reached" "$ERR" && ok "cap note on stderr" || bad "missing cap note"

echo "== malformed counters fail OPEN =="
arm_review main review-main 3x 99
expect_allow "malformed cap allows"
grep -q "malformed" "$ERR" && ok "malformed note on stderr" || bad "missing malformed note"

echo "== leading-zero counters fail OPEN (octal trap: 08 breaks [[ -ge ]] and the bump) =="
arm_review main review-main 3 08
expect_allow "blocks=08 allows (not an infinite fail-closed loop)"
arm_review main review-main 08 0
expect_allow "cap=08 allows"

echo "== pre-0.5 armed file (no log_bytes_at_arming) fails OPEN with a re-arm note =="
mkdir -p "$SD"
printf 'branch=main\nthread=review-main\nlens=correctness\ncap=3\nblocks=0\nrounds_at_arming=1\n' > "$SD/autoreview.armed"
printf 'REPLY:\n  APPROVE\n---\n' > "$SD/review-main.log"   # stale APPROVE that 0.4 semantics would scan
expect_allow "pre-0.5 autoreview armed file allows (does not scan whole log)"
grep -q "pre-0.5 arming" "$ERR" && ok "re-arm note on stderr" || bad "missing pre-0.5 note"

echo "== present-but-EMPTY required fields are malformed, not defaults =="
# log_bytes_at_arming= (empty) passes has_field; it must NOT become offset 0
# and scan the stale whole-log APPROVE above.
printf 'branch=main\nthread=review-main\nlens=correctness\ncap=3\nblocks=0\nlog_bytes_at_arming=\n' > "$SD/autoreview.armed"
expect_allow "empty log_bytes_at_arming fails open (no whole-log scan)"
grep -q "malformed" "$ERR" && ok "empty offset -> malformed note" || bad "missing malformed note for empty offset"
printf 'branch=main\nthread=review-main\nlens=correctness\ncap=\nblocks=0\nlog_bytes_at_arming=0\n' > "$SD/autoreview.armed"
expect_allow "empty cap fails open"
printf 'branch=main\nthread=review-main\nlens=correctness\ncap=3\nblocks=\nlog_bytes_at_arming=0\n' > "$SD/autoreview.armed"
expect_allow "empty blocks fails open"
rm -f "$SD/review-main.log"

echo "== quote-in-branch cannot break JSON =="
arm_review main 'review-x' 3 0
sed -i.bak 's/^lens=.*/lens=correct"ness\\evil/' "$SD/autoreview.armed" && rm -f "$SD/autoreview.armed.bak"
expect_valid_json "reason sanitized to valid JSON"

echo "== control chars (tab/CR) in lens cannot break JSON =="
printf 'branch=main\nthread=review-x\nlens=corr\tect\rness\ncap=3\nblocks=0\nlog_bytes_at_arming=0\n' > "$SD/autoreview.armed"
expect_valid_json "control-char lens sanitized to valid JSON"

echo "== unknown printable lens falls back to the gate default =="
arm_review main review-main 3 0 0 totally-bogus-lens
run_hook
printf '%s' "$OUT" | grep -q -- '--lens correctness' && ok "bogus lens replaced by correctness" || bad "bogus lens leaked (got: $OUT)"

echo "== invalid thread name falls back to slugified branch =="
git checkout -qb 'feat/slash' 2>/dev/null
arm_review 'feat/slash' 'bad thread name!!' 3 0
run_hook
printf '%s' "$OUT" | grep -q -- '--thread review-feat-slash' && ok "fallback thread slugified" || bad "fallback not slugified (got: $OUT)"
git checkout -q main

echo "== branch chars outside the driver alphabet slug to '-' (git allows +, # ...) =="
git checkout -qb 'feat/a+b' 2>/dev/null
arm_review 'feat/a+b' 'bad thread name!!' 3 0
run_hook
printf '%s' "$OUT" | grep -q -- '--thread review-feat-a-b' && ok "plus-sign branch slugs to a driver-valid thread" || bad "invalid slug leaked (got: $OUT)"
git checkout -q main

echo "== APPROVE appended after the arming offset releases =="
printf '[t] mode=initial thread=review-main round=1\nPROMPT:\n  p\nREPLY:\n  looks wrong\n  REQUEST_CHANGES\n---\n' > "$SD/review-main.log"
OFF=$(logsize "$SD/review-main.log")
arm_review main review-main 3 0 "$OFF"
printf '[t] mode=resume thread=review-main round=2\nPROMPT:\n  p\nREPLY:\n  all addressed\n  APPROVE\n---\n' >> "$SD/review-main.log"
expect_allow "post-arming APPROVE releases"

echo "== post-arming --json reply with verdict EMBEDDED IN JSON (not standalone) does NOT release =="
printf '[t] mode=initial thread=review-main round=1\nPROMPT:\n  p\nREPLY:\n  looks wrong\n  REQUEST_CHANGES\n---\n' > "$SD/review-main.log"
OFF=$(logsize "$SD/review-main.log")
arm_review main review-main 3 0 "$OFF"
printf '[t] mode=resume thread=review-main round=2\nPROMPT:\n  p\nREPLY:\n  {"verdict":"APPROVE","findings":[]}\n---\n' >> "$SD/review-main.log"
expect_block "JSON-embedded verdict (not a standalone line) does not release the gate"

echo "== STALE APPROVE before the arming offset does NOT release =="
printf '[t] mode=initial thread=review-main round=1\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n' > "$SD/review-main.log"
OFF=$(logsize "$SD/review-main.log")
arm_review main review-main 3 0 "$OFF"
expect_block "stale APPROVE still blocks (nothing appended since arming)"

echo "== STALE APPROVE + post-arming NON-VERDICT round does NOT release =="
printf '[t] mode=resume thread=review-main round=2\nPROMPT:\n  reply text\nREPLY:\n  thanks, noted — no verdict here\n---\n' >> "$SD/review-main.log"
arm_review main review-main 3 0 "$OFF"
expect_block "pre-arming APPROVE beyond a non-verdict round still blocks"

echo "== log rotated/reset since arming: offset larger than log falls back to whole log =="
printf 'REPLY:\n  APPROVE\n---\n' > "$SD/review-main.log"   # tiny fresh log (post-rotation)
arm_review main review-main 3 0 99999
expect_allow "rotated log parsed in full"

echo "== a single reply longer than any line window still yields its verdict =="
{ printf 'REPLY:\n'; i=1; while [ "$i" -le 450 ]; do printf '  filler line %s\n' "$i"; i=$((i+1)); done; printf '  APPROVE\n---\n'; } > "$SD/review-main.log"
arm_review main review-main 3 0 0
expect_allow "450-line reply ending in APPROVE releases (no tail window)"

echo "== verdict literal inside a PROMPT section cannot fake APPROVE =="
printf 'PROMPT:\n  earlier you said: APPROVE\n  APPROVE\nREPLY:\n  no verdict here\n---\n' > "$SD/review-main.log"
arm_review main review-main 3 0 0
expect_block "standalone APPROVE in PROMPT does not release"

echo "== contract line in PROMPT does not fake a verdict =="
printf 'PROMPT:\n  - Last line is the verdict: APPROVE | REQUEST_CHANGES | COMMENT\nREPLY:\n  no verdict yet\n---\n' > "$SD/review-main.log"
expect_block "no standalone verdict -> still blocks"

echo "== explicit REQUEST_CHANGES in REPLY keeps blocking =="
printf 'REPLY:\n  findings...\n  REQUEST_CHANGES\n---\n' > "$SD/review-main.log"
expect_block "REQUEST_CHANGES blocks"

echo "== Verdict: APPROVE prefixed form also releases =="
printf 'REPLY:\n  Verdict: APPROVE\n---\n' > "$SD/review-main.log"
arm_review main review-main 3 0 0
expect_allow "prefixed verdict releases"

echo "== wrong branch allows =="
arm_review other-branch review-other 3 0
expect_allow "branch mismatch allows"

echo "== detached HEAD allows (no branch to scope to) =="
arm_review HEAD review-HEAD 3 0
git checkout -q --detach HEAD
expect_allow "detached HEAD allows even with branch=HEAD armed"
git checkout -q main
rm -f "$SD/autoreview.armed" "$SD/review-main.log"
git checkout -q f.txt

echo "== read-only state dir fails OPEN (unpersistable counter must not block) =="
arm_review main review-main 3 0
echo dirty >> f.txt
chmod 555 "$SD"
expect_allow "unwritable state dir allows"
grep -q "could not persist" "$ERR" && ok "persist-failure note on stderr" || bad "missing persist-failure note"
chmod 755 "$SD"
rm -f "$SD/autoreview.armed"
git checkout -q f.txt

echo "== autoplan: blocks on plan dirt, reason carries the command file =="
mkdir -p docs/plans && echo p > docs/plans/x.md
printf '[t] mode=initial thread=plan-main round=1\nPROMPT:\n  p\nREPLY:\n  objections\n---\n' > "$SD/plan-main.log"
arm_plan main plan-main 2 0 "$(logsize "$SD/plan-main.log")"
expect_block "autoplan blocks on plan dirt"
printf '%s' "$OUT" | grep -q 'commands/plan.md' && ok "autoplan reason carries plan.md path" || bad "autoplan reason lacks command file path"

echo "== autoplan: /thread-new reset alone does NOT release (log untouched by reset) =="
rm -f "$SD/plan-main.rounds" "$SD/plan-main.id"   # what /thread-new actually deletes
expect_block "bare reset cannot fake a run"

echo "== autoplan: a fresh /plan run releases (log grew), even after a reset =="
printf '[t] mode=initial thread=plan-main round=1\nPROMPT:\n  p2\nREPLY:\n  re-checked\n---\n' >> "$SD/plan-main.log"
expect_allow "autoplan releases on log growth"

echo "== autoplan: pre-0.5 armed file fails OPEN with a re-arm note =="
printf 'branch=main\nthread=plan-main\nlens=stress-test\ncap=2\nblocks=0\nrounds_at_arming=5\n' > "$SD/autoplan.armed"
expect_allow "pre-0.5 autoplan armed file allows"
grep -q "pre-0.5 arming" "$ERR" && ok "autoplan re-arm note on stderr" || bad "missing autoplan pre-0.5 note"

echo "== autoplan: present-but-empty offset is malformed (must not release on pre-existing log) =="
printf 'branch=main\nthread=plan-main\nlens=stress-test\ncap=2\nblocks=0\nlog_bytes_at_arming=\n' > "$SD/autoplan.armed"
expect_allow "empty autoplan offset fails open"
grep -q "malformed" "$ERR" && ok "autoplan empty-offset malformed note" || bad "missing autoplan malformed note"

echo "== autoplan: cap is the hard terminator too =="
arm_plan main plan-main 2 2 "$(logsize "$SD/plan-main.log")"
expect_allow "autoplan cap reached allows"
grep -q "round cap (2) reached" "$ERR" && ok "autoplan cap note on stderr" || bad "missing autoplan cap note"
rm -rf docs "$SD/autoplan.armed" "$SD/plan-main.log"

# ── Gate TTL pre-pass (14-day auto-expiry, armed_at epoch) ──────────────────
NOW_S="$(date +%s)"
OLD_AT=$(( NOW_S - 1209600 - 3600 ))   # 14 days + 1 hour ago -> expired
# docs/plans dirt serves both gates below: it is plan dirt AND code dirt.
mkdir -p docs/plans && echo p > docs/plans/ttl.md

echo "== TTL t1: expired autoreview + fresh dirty autoplan -> autoreview removed, autoplan still blocks =="
arm_review main review-main 3 0
printf 'armed_at=%s\n' "$OLD_AT" >> "$SD/autoreview.armed"
arm_plan main plan-main 2 0
printf 'armed_at=%s\n' "$NOW_S" >> "$SD/autoplan.armed"
expect_block "expired autoreview does not suppress the fresh autoplan gate"
printf '%s' "$OUT" | grep -q 'commands/plan.md' && ok "block came from autoplan" || bad "expected the autoplan block (got: $OUT)"
[[ ! -f "$SD/autoreview.armed" ]] && ok "expired autoreview.armed removed" || bad "expired autoreview.armed still present"
grep -q "autoreview gate expired after 14 days" "$ERR" && ok "autoreview expiry note on stderr" || bad "missing autoreview expiry note"
rm -f "$SD/autoplan.armed"

echo "== TTL t2: fresh autoreview + expired autoplan -> autoreview blocks, autoplan removed =="
arm_review main review-main 3 0
printf 'armed_at=%s\n' "$NOW_S" >> "$SD/autoreview.armed"
arm_plan main plan-main 2 0
printf 'armed_at=%s\n' "$OLD_AT" >> "$SD/autoplan.armed"
expect_block "fresh autoreview still blocks"
printf '%s' "$OUT" | grep -q 'commands/review.md' && ok "block came from autoreview" || bad "expected the autoreview block (got: $OUT)"
[[ ! -f "$SD/autoplan.armed" ]] && ok "expired autoplan.armed removed BEFORE the autoreview block exited the hook" || bad "expired autoplan.armed still present"
grep -q "autoplan gate expired after 14 days" "$ERR" && ok "autoplan expiry note on stderr" || bad "missing autoplan expiry note"

echo "== TTL t3: both expired -> both removed, hook allows =="
arm_review main review-main 3 0
printf 'armed_at=%s\n' "$OLD_AT" >> "$SD/autoreview.armed"
arm_plan main plan-main 2 0
printf 'armed_at=%s\n' "$OLD_AT" >> "$SD/autoplan.armed"
expect_allow "both gates expired -> allow despite dirt"
[[ ! -f "$SD/autoreview.armed" && ! -f "$SD/autoplan.armed" ]] && ok "both armed files removed" || bad "an expired armed file survived"
grep -q "autoreview gate expired" "$ERR" && grep -q "autoplan gate expired" "$ERR" && ok "both expiry notes on stderr" || bad "missing an expiry note"

echo "== TTL t4: both fresh -> exact 0.7 behavior (autoreview fires first, counter bumps, files kept) =="
arm_review main review-main 3 0
printf 'armed_at=%s\n' "$NOW_S" >> "$SD/autoreview.armed"
arm_plan main plan-main 2 0
printf 'armed_at=%s\n' "$NOW_S" >> "$SD/autoplan.armed"
expect_block "fresh gates block exactly as before"
printf '%s' "$OUT" | grep -q 'commands/review.md' && ok "autoreview gate fires first" || bad "wrong gate fired (got: $OUT)"
[[ "$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")" == "1" ]] && ok "blocks counter increments (armed_at survives the bump)" || bad "blocks counter not incremented"
[[ -f "$SD/autoplan.armed" ]] && ok "fresh autoplan.armed untouched" || bad "fresh autoplan.armed removed"
rm -f "$SD/autoplan.armed"

echo "== TTL t5: malformed / future armed_at -> TTL skipped, gate behavior unchanged =="
arm_review main review-main 3 0
printf 'armed_at=banana\n' >> "$SD/autoreview.armed"
expect_block "malformed armed_at still blocks"
[[ -f "$SD/autoreview.armed" ]] && ok "malformed armed_at file not removed" || bad "malformed armed_at file removed"
arm_review main review-main 3 0
printf 'armed_at=%s\n' $(( NOW_S + 864000 )) >> "$SD/autoreview.armed"
expect_block "future armed_at still blocks"
[[ -f "$SD/autoreview.armed" ]] && ok "future armed_at file not removed" || bad "future armed_at file removed"

echo "== TTL t6: 0.7-format armed file (no armed_at) with ancient mtime is TTL-exempt =="
arm_review main review-main 3 0
touch -t 202001010000 "$SD/autoreview.armed"
expect_block "0.7 armed file still blocks (TTL keys on armed_at, never mtime)"
[[ -f "$SD/autoreview.armed" ]] && ok "0.7 armed file not removed" || bad "0.7 armed file removed by TTL"

echo "== TTL t7: unremovable expired file -> treated absent this run, loud warning =="
arm_review main review-main 3 0
printf 'armed_at=%s\n' "$OLD_AT" >> "$SD/autoreview.armed"
chmod 555 "$SD"
expect_allow "unremovable expired gate does not block this run"
grep -q "could not be removed" "$ERR" && ok "loud unremovable warning on stderr" || bad "missing unremovable warning"
chmod 755 "$SD"
[[ -f "$SD/autoreview.armed" ]] && ok "file survived the failed rm (as expected)" || bad "file unexpectedly gone despite read-only dir"
rm -f "$SD/autoreview.armed"
rm -rf docs

# ── Cycle model (0.9): fingerprint baseline, per-cycle release ───────────────
# Everything above arms WITHOUT fp_at_arming, i.e. exercises the pre-0.9
# compatibility path. These arm WITH it, which is what a 0.9 command writes.

# Derived from $HOOK (already absolute) — $0 is relative to the ORIGINAL cwd
# and the suite has long since cd'd into the fixture repo.
FPSH="$(cd "$(dirname "$HOOK")/../scripts" && pwd)/gate-fingerprint.sh"
fp_now()  { bash "$FPSH" "$@"; }
arm_review_fp() { # branch thread cap blocks log_bytes fp
  mkdir -p "$SD"
  printf 'branch=%s\nthread=%s\nlens=correctness\ncap=%s\nblocks=%s\nlog_bytes_at_arming=%s\nfp_at_arming=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" > "$SD/autoreview.armed"
}
reply_log() { printf 'REPLY:\n  %s\n' "$1" > "$SD/review-main.log"; }   # overwrite: one verdict, at offset 0

echo "== fingerprint: identical state hashes identically, any change moves it =="
git checkout -q -- . 2>/dev/null; git clean -qfd 2>/dev/null
FP_A="$(fp_now)"
[[ -n "$FP_A" ]] && ok "fingerprint is non-empty in a repo" || bad "empty fingerprint in a repo"
[[ "$(fp_now)" == "$FP_A" ]] && ok "stable across calls with no change" || bad "unstable fingerprint"
echo edit >> f.txt
FP_DIRTY="$(fp_now)"
[[ "$FP_DIRTY" != "$FP_A" ]] && ok "an uncommitted edit moves it" || bad "edit did not move the fingerprint"
git add -A >/dev/null && git commit -qm "cycle-test commit"
FP_COMMITTED="$(fp_now)"
# THE property the old dirty-tree test lacked: committing is a CHANGE, not a
# return to the pre-edit state. Without this, committing the fixes read as
# "nothing to review" while the verdict was still REQUEST_CHANGES.
[[ "$FP_COMMITTED" != "$FP_A" && "$FP_COMMITTED" != "$FP_DIRTY" ]] \
  && ok "committing moves it too (never back to the pre-edit state)" || bad "commit collapsed the fingerprint (a: $FP_A dirty: $FP_DIRTY committed: $FP_COMMITTED)"
# The gate's own bookkeeping must never count as reviewable work, or the gate
# re-arms on the driver's writes until the cap.
mkdir -p "$SD"; echo noise > "$SD/scratch.log"
[[ "$(fp_now)" == "$FP_COMMITTED" ]] && ok "state-dir writes are excluded" || bad "state dir leaked into the fingerprint"
rm -f "$SD/scratch.log"
# Untracked CONTENT counts. A new plan doc or module is untracked for its whole
# first life, and neither porcelain nor `git diff HEAD` moves while it is
# edited — a gate blind to this releases once and never fires again.
echo "v1" > newfile.txt
FP_U1="$(fp_now)"
[[ "$FP_U1" != "$FP_COMMITTED" ]] && ok "a new untracked file moves it" || bad "new untracked file invisible"
echo "v2" >> newfile.txt
[[ "$(fp_now)" != "$FP_U1" ]] && ok "EDITING an untracked file moves it" || bad "untracked edit invisible (porcelain-only blind spot)"
rm -f newfile.txt

echo "== hole 1: committing the fixes does NOT silence an open REQUEST_CHANGES =="
BASE="$(fp_now)"
arm_review_fp main review-main 3 0 0 "$BASE"
reply_log REQUEST_CHANGES
expect_allow "clean at the baseline -> allow"
echo "risky" >> f.txt
expect_block "uncommitted change + REQUEST_CHANGES -> block"
git add -A >/dev/null && git commit -qm "address findings"
expect_block "COMMITTED change + REQUEST_CHANGES still blocks (was: allow)"

echo "== hole 2: one APPROVE does not open the gate for the rest of the arming =="
BASE="$(fp_now)"
arm_review_fp main review-main 3 0 0 "$BASE"
echo "work" >> f.txt
expect_block "new work -> block"
reply_log APPROVE
expect_allow "APPROVE releases the state it approved"
REL="$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")"
[[ "$REL" == "$(fp_now)" ]] && ok "released_fp records the approved state" || bad "released_fp not recorded (got '$REL')"
[[ "$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")" == "0" ]] && ok "round budget refilled for the next cycle" || bad "blocks not reset on release"
NEWOFF="$(sed -n 's/^log_bytes_at_arming=//p' "$SD/autoreview.armed")"
[[ "$NEWOFF" == "$(logsize "$SD/review-main.log")" ]] && ok "verdict window advanced past the releasing APPROVE" || bad "log offset not advanced (got '$NEWOFF')"
expect_allow "no further change -> still allow (idempotent)"
echo "brand new unreviewed code" >> f.txt
expect_block "NEW code after the APPROVE blocks again (was: allow forever)"

echo "== the stale APPROVE that released cycle 1 cannot release cycle 2 =="
# The log still ends in APPROVE, but it sits before the advanced offset.
grep -q APPROVE "$SD/review-main.log" && ok "precondition: log still ends in APPROVE" || bad "precondition broken"
expect_block "same APPROVE, new cycle -> still blocks"

echo "== cap still terminates a cycle that never earns an APPROVE =="
# Fresh arming so the budget is unambiguous: the refill on release means the
# counter carried over from the cycles above is not a fixed number.
git add -A >/dev/null && git commit -qm "settle before cap test"
reply_log REQUEST_CHANGES                               # nothing in this cycle will release
arm_review_fp main review-main 2 0 0 "$(fp_now)"
echo "never approved" >> f.txt
expect_block "cap block 1/2"
expect_block "cap block 2/2"
expect_allow "cap reached -> fail open"
grep -q "round cap" "$ERR" && ok "cap warning on stderr" || bad "no cap warning"

echo "== pre-0.9 armed file keeps the old dirty-tree behaviour (no silent change) =="
git add -A >/dev/null && git commit -qm "settle"
arm_review main review-main 3 0        # no fp_at_arming
reply_log REQUEST_CHANGES
expect_allow "clean tree + legacy armed file -> allow, exactly as before"
echo legacy >> f.txt
expect_block "dirty tree + legacy armed file -> block, exactly as before"
git add -A >/dev/null && git commit -qm "legacy commit"
expect_allow "legacy file: committing still releases (documented old behaviour)"
rm -f "$SD/autoreview.armed"

echo "== a missing fingerprint script fails OPEN, loudly =="
BASE="$(fp_now)"
arm_review_fp main review-main 3 0 0 "$BASE"
echo unreviewed >> f.txt
expect_block "precondition: blocks while the script is present"
HOOK_DIR="$(dirname "$HOOK")"; mv "$HOOK_DIR/../scripts/gate-fingerprint.sh" "$T/fp.bak"
expect_allow "no fingerprint script -> fail open"
grep -q "gate-fingerprint.sh not found" "$ERR" && ok "loud warning names the missing script" || bad "silent fallback"
mv "$T/fp.bak" "$HOOK_DIR/../scripts/gate-fingerprint.sh"
rm -f "$SD/autoreview.armed"
git add -A >/dev/null && git commit -qm "settle 2"

echo "== autoplan: a released cycle re-arms on the NEXT plan edit =="
mkdir -p docs/plans
arm_plan_fp() { # branch thread cap blocks log_bytes fp
  mkdir -p "$SD"
  printf 'branch=%s\nthread=%s\nlens=stress-test\ncap=%s\nblocks=%s\nlog_bytes_at_arming=%s\nfp_at_arming=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" > "$SD/autoplan.armed"
}
PFP="$(fp_now docs/plans docs/PLANS)"
arm_plan_fp main plan-main 2 0 0 "$PFP"
echo "# plan v1" > docs/plans/p.md
expect_block "changed plan doc -> block"
printf 'REPLY:\n  stress-tested\n' > "$SD/plan-main.log"      # a dispatch appended
expect_allow "post-arming dispatch releases"
[[ -n "$(sed -n 's/^released_fp=//p' "$SD/autoplan.armed")" ]] && ok "autoplan records released_fp" || bad "autoplan release not recorded"
expect_allow "no further plan change -> still allow"
echo "# plan v2 — new section" >> docs/plans/p.md
expect_block "NEXT plan edit needs its own dispatch (was: allow forever)"
rm -f "$SD/autoplan.armed"
rm -rf docs; git add -A >/dev/null; git commit -qm "cleanup" >/dev/null 2>&1

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
