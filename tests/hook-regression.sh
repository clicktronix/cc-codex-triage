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

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
