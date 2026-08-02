#!/usr/bin/env bash
# Regression suite for hooks/stop-hook.sh. No Codex needed — synthetic state.
# Usage: bash tests/hook-regression.sh   (exit 0 = all pass)
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

HOOK="$(cd "$(dirname "$0")/.." && pwd)/plugins/cc-codex-triage/hooks/stop-hook.sh"
[[ -f "$HOOK" ]] || { echo "hook not found: $HOOK"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cc-hook-test.XXXXXX")"
ERR="$(mktemp "${TMPDIR:-/tmp}/cc-hook-err.XXXXXX")"   # OUTSIDE the test repo — an err file inside would dirty the tree
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T" "$ERR"' EXIT
cd "$T"


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
# A log OPENING with PROMPT never sets the in-reply flag, so it would pass even
# without the section rule. The load-bearing order is reply-then-prompt: a
# /reply quoting "earlier you said APPROVE" must not release the gate.
printf 'REPLY:\n  REQUEST_CHANGES\n---\nPROMPT:\n  earlier you said: APPROVE\n  APPROVE\n' > "$SD/review-main.log"
arm_review main review-main 3 0 0
expect_block "APPROVE quoted back in a later PROMPT does not release"
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

echo "== TTL t8: expiry takes the armed-state mutex like every other mutation =="
# Deleting the file mutates armed state, so an unserialized expiry could land
# between a fresh arming's write and its first read and silently discard it.
chmod 755 "$SD" 2>/dev/null
arm_review main review-main 3 0
printf 'armed_at=%s\n' "$OLD_AT" >> "$SD/autoreview.armed"
mkdir -p "$SD/autoreview.armed.lock"; printf 'held-elsewhere' > "$SD/autoreview.armed.lock/owner"
expect_allow "an expired gate whose lock is held does not block either"
[[ -f "$SD/autoreview.armed" ]] && ok "and is NOT deleted without the lock" || bad "TTL deleted the armed file without holding the lock"
grep -q "could not be removed" "$ERR" && ok "and the refusal is reported" || bad "silent TTL refusal"
[[ "$(cat "$SD/autoreview.armed.lock/owner" 2>/dev/null)" == "held-elsewhere" ]] \
  && ok "and the foreign lock survives" || bad "TTL released a lock it did not own"
rm -rf "$SD/autoreview.armed.lock"; rm -f "$SD/autoreview.armed"
rm -rf docs

# ── Cycle model (0.9): fingerprint baseline, per-cycle release ───────────────
# Everything above arms WITHOUT fp_at_arming, i.e. exercises the pre-0.9
# compatibility path. These arm WITH it, which is what a 0.9 command writes.

# Derived from $HOOK (already absolute) — $0 is relative to the ORIGINAL cwd
# and the suite has long since cd'd into the fixture repo.
FPSH="$(cd "$(dirname "$HOOK")/../scripts" && pwd)/gate-fingerprint.sh"
fp_now()  { bash "$FPSH" "$@"; }
arm_review_fp() { # branch thread cap blocks log_bytes fp [log_gen]
  mkdir -p "$SD"
  printf 'branch=%s\nthread=%s\nlens=correctness\ncap=%s\nblocks=%s\nlog_bytes_at_arming=%s\nlog_gen_at_arming=%s\nfp_at_arming=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "${7:-0}" "$6" > "$SD/autoreview.armed"
}
arm_plan_fp() { # branch thread cap blocks log_bytes fp [log_gen]
  mkdir -p "$SD"
  printf 'branch=%s\nthread=%s\nlens=stress-test\ncap=%s\nblocks=%s\nlog_bytes_at_arming=%s\nlog_gen_at_arming=%s\nfp_at_arming=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "${7:-0}" "$6" > "$SD/autoplan.armed"
}
# One verdict at offset 0, plus the dispatch snapshot the driver ALWAYS writes
# beside it: without it the fixture is a log the 0.9 driver cannot produce, and
# the gate refuses to release on that. Snapshot taken NOW = "just reviewed this".
reply_log() {
  printf 'REPLY:\n  %s\n' "$1" > "$SD/review-main.log"
  printf '%s\n' "$(fp_now)" > "$SD/review-main.dispatch-fp"
}

echo "== verdict parser: the exit-code contract =="
# 0 a value, 1 nothing, 2 cannot be attributed. Status rather than a reserved
# word on stdout, so no caller has to remember to string-compare a hash.
VSH_C="$(cd "$(dirname "$HOOK")/../scripts" && pwd)/last-verdict.sh"
CLOG="$T/contract.log"
printf 'REPLY:\n  APPROVE\n' > "$CLOG"
bash "$VSH_C" "$CLOG" 0 >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "a verdict exits 0" || bad "verdict did not exit 0"
printf 'REPLY:\n  nothing here\n' > "$CLOG"
bash "$VSH_C" "$CLOG" 0 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "no verdict exits 1" || bad "missing verdict did not exit 1"
bash "$VSH_C" "$T/does-not-exist.log" 0 >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "an absent log exits 1" || bad "absent log did not exit 1"
printf 'REPLY:\n  APPROVE\n' > "$CLOG"
bash "$VSH_C" "$CLOG" 0 --fp >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "a markerless LATEST record exits 1 (sidecar may still answer)" || bad "markerless latest record: wrong status"
printf '[t1] mode=initial round=1\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n[t2] mode=resume round=2 fp=%s\nPROMPT:\n  p\nREPLY:\n  no verdict\n---\n' "$(printf 'a%.0s' $(seq 40))" > "$CLOG"
bash "$VSH_C" "$CLOG" 0 --fp >/dev/null 2>&1; [[ $? -eq 2 ]] && ok "a markerless verdict behind a later record exits 2" || bad "unattributable verdict: wrong status"

echo "== verdict parser: the formats Codex actually writes =="
VSH="$(cd "$(dirname "$HOOK")/../scripts" && pwd)/last-verdict.sh"
VLOG="$T/verdict.log"
v() { # $1 = reply body line, $2 = expected verdict ('-' for none)
  printf 'REPLY:\n%s\n' "$1" > "$VLOG"
  local got; got="$(bash "$VSH" "$VLOG" 0)"; got="${got:--}"
  [[ "$got" == "$2" ]] && ok "[$1] -> $2" || bad "[$1] -> got '$got', want '$2'"
}
# Accepted: the contract asks for a bare verdict, but a production thread went
# five rounds without one matching, so emphasis and heading marks are tolerated.
v '  APPROVE'                 APPROVE
v '  ## APPROVE'              APPROVE
v '  ## Verdict: APPROVE'     APPROVE
v '  **APPROVE**'             APPROVE
v '  __APPROVE__'             APPROVE
v '  Verdict: **APPROVE**'    APPROVE
v '  Verdict: APPROVE.'       APPROVE
v '  COMMENT'                 COMMENT
# The underscore in REQUEST_CHANGES is why the strip is anchored to the line
# ENDS: a global strip of emphasis characters turns it into REQUESTCHANGES and
# silently stops every change request from being seen.
v '  REQUEST_CHANGES'         REQUEST_CHANGES
v '  REQUEST_CHANGES---'      REQUEST_CHANGES
v '  ## REQUEST_CHANGES'      REQUEST_CHANGES
# Refused: any line carrying other words. Tolerating those would also accept
# the first of these, which is a REFUSAL to approve.
v '  > APPROVE'                                     -
v '  - APPROVE'                                     -
v '  * APPROVE'                                     -
v '  + APPROVE'                                     -
v '  *   APPROVE'                                   -
v '  > **APPROVE**'                                 -
v '  ## Verdict: very close, but not quite APPROVE'  -
v '  I would not give APPROVE here'                  -
v '  **Final review decision: APPROVE.**'            -
v '  APPROVE the migration first'                    -
# Section boundary. The order matters: a log that OPENS with PROMPT never sets
# the in-reply flag, so it passes whether or not the boundary rule exists. The
# real hazard is a reply followed by a /reply quoting the word back.
printf 'REPLY:\n  REQUEST_CHANGES\n---\nPROMPT:\n  earlier you said: APPROVE\n  APPROVE\n' > "$VLOG"
[[ "$(bash "$VSH" "$VLOG" 0)" == "REQUEST_CHANGES" ]] \
  && ok "a verdict quoted back inside a later PROMPT cannot override the reply" \
  || bad "PROMPT-section verdict leaked (got '$(bash "$VSH" "$VLOG" 0)')"
printf 'PROMPT:\n  APPROVE\n' > "$VLOG"
[[ -z "$(bash "$VSH" "$VLOG" 0)" ]] && ok "a log that opens with a PROMPT yields no verdict" || bad "PROMPT-only log produced a verdict"
# The gate and /status must never disagree about the same log.
printf 'REPLY:\n  ## APPROVE\n' > "$VLOG"
[[ "$(bash "$VSH" "$VLOG" 0)" == "APPROVE" ]] && ok "status.sh and the hook share this one parser" || bad "shared parser mismatch"

echo "== fingerprint: an unreadable path yields NOTHING, never a fabricated hash =="
# Nothing printed when it cannot compute — a confident wrong hash is the one
# outcome it promises never to produce. A dangling symlink is NOT such a case:
# git records the link itself, so it must keep hashing fine.
git checkout -q -- . 2>/dev/null; git clean -qfd 2>/dev/null
echo v1 > zzz.txt
FP_BEFORE="$(fp_now)"
ln -s /nonexistent/target aaa-dangling
[[ -n "$(fp_now)" && "$(fp_now)" != "$FP_BEFORE" ]] && ok "a dangling symlink is hashable content, not a failure" || bad "dangling symlink broke the fingerprint"
rm -f aaa-dangling
# The cache is cleared FIRST: chmod does not change content, so a warm stat
# cache legitimately answers without re-reading the file and no degradation
# happens. This asserts the cold-compute failure path, and leaving the cache in
# made the suite flaky — the same tree answering two ways run to run.
rm -f "$SD/gate-index"
chmod 000 zzz.txt
[[ -z "$(fp_now)" ]] && ok "an unreadable file -> empty (caller fails open)" || bad "fabricated a hash for an unreadable file"
# Degrading to the weaker dirty-tree test must be as loud as a missing script.
arm_review_fp main review-main 3 0 0 "$FP_BEFORE"
run_hook
grep -q "fingerprint could not be computed" "$ERR" && ok "degraded mode announces itself on stderr" || bad "silent degradation"
rm -f "$SD/autoreview.armed"
chmod 644 zzz.txt
[[ "$(fp_now)" == "$FP_BEFORE" ]] && ok "recovers to the same hash once readable" || bad "did not recover"
rm -f zzz.txt

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
# It hashes CONTENT, so committing is not itself an event, in both directions:
# a fix survives its own commit and keeps the gate engaged, while committing
# already-approved bytes costs no review round.
[[ "$FP_COMMITTED" != "$FP_A" ]] \
  && ok "a change survives its own commit (never back to the pre-edit state)" || bad "commit collapsed to the pre-edit fingerprint"
[[ "$FP_COMMITTED" == "$FP_DIRTY" ]] \
  && ok "committing identical content is NOT a change (burns no gate round)" || bad "commit of identical content moved the fingerprint (dirty: $FP_DIRTY committed: $FP_COMMITTED)"
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

echo "== fingerprint: scoped pathspecs that match nothing are normal, not an error =="
# "No plan documents yet" is the ordinary state of a fresh branch, and `git add`
# is FATAL on a pathspec matching nothing. Returning empty here would silently
# disable the autoplan gate on every branch that has not written a plan yet.
EMPTY_SCOPE="$(fp_now docs/plans docs/PLANS)"
[[ -n "$EMPTY_SCOPE" ]] && ok "absent plan dirs still yield a fingerprint" || bad "absent plan dirs returned empty (gate would silently disable)"
[[ "$(fp_now docs/plans docs/PLANS)" == "$EMPTY_SCOPE" ]] && ok "and it is stable" || bad "unstable empty-scope fingerprint"
mkdir -p docs/plans; echo "# p" > docs/plans/p.md
[[ "$(fp_now docs/plans docs/PLANS)" != "$EMPTY_SCOPE" ]] && ok "a first plan doc moves it" || bad "first plan doc invisible"
rm -rf docs

echo "== the index cache changes speed, never the answer =="
# Whole-tree runs seed the throwaway index from a cached copy so git's stat
# cache survives between turns. A cache that altered the hash — or one that went
# stale across an edit — would be a gate that fires at random.
rm -f "$SD/gate-index"
COLD1="$(fp_now)"
WARM1="$(fp_now)"
[[ "$COLD1" == "$WARM1" ]] && ok "a warm run agrees with a cold one" || bad "cache changed the hash: $COLD1 vs $WARM1"
echo "edited under a warm cache" >> f.txt
WARM2="$(fp_now)"
[[ "$WARM2" != "$WARM1" ]] && ok "and still sees an edit made since it was written" || bad "the cache hid an edit"
rm -f "$SD/gate-index"
[[ "$(fp_now)" == "$WARM2" ]] && ok "and a cold run agrees with the warm one again" || bad "cold and warm diverge after an edit"
# A corrupt cache is not self-repairing — git rejects an invalid index outright,
# so without the retry the run returns nothing and recopies the same bad file
# every turn: a PERMANENT fall back to the dirty-tree predicate.
COLD_GOOD="$(fp_now)"
printf 'not an index at all' > "$SD/gate-index"
[[ "$(fp_now)" == "$COLD_GOOD" ]] && ok "a corrupt cache is discarded and the run still answers" || bad "corrupt cache killed the fingerprint"
[[ "$(fp_now)" == "$COLD_GOOD" ]] && ok "and the next run is not degraded either" || bad "corrupt cache persisted"
# A file that becomes gitignored must leave the hash. Ignore rules do not evict
# entries ALREADY in a seeded index, so the cache kept hashing it. The file has
# to stay on disk for this: deleting it makes `add -A` drop the entry anyway,
# which is why the first version of this test could not fail.
# The rule goes in .git/info/exclude, NOT .gitignore: .gitignore is itself part
# of the tree, so editing it moves the hash whether or not the purge works and
# the comparison below could not fail.
rm -f "$SD/gate-index"
echo "content" > cache-ignored.tmp
WITH_FILE="$(fp_now)"                     # cold, then seeds the cache with it tracked
EXCL="$(git rev-parse --git-path info/exclude)"; mkdir -p "$(dirname "$EXCL")"
echo "cache-ignored.tmp" >> "$EXCL"
IGNORED_WARM="$(fp_now)"                  # warm cache, file still on disk, now ignored
[[ "$IGNORED_WARM" != "$WITH_FILE" ]] && ok "a newly ignored file leaves the hash even from a warm cache" || bad "the cache kept hashing an ignored file"
rm -f "$SD/gate-index"
[[ "$(fp_now)" == "$IGNORED_WARM" ]] && ok "and a cold run agrees" || bad "warm and cold disagree on the ignored file"
rm -f cache-ignored.tmp
: > "$EXCL"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1
git checkout -q -- f.txt 2>/dev/null
[[ ! -e "$SD/gate-index.$$" ]] && ok "no cache temp left behind" || bad "cache temp leaked"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== fingerprint: dirty submodule content is inside the cycle =="
# write-tree records a submodule as a GITLINK, so edits inside one leave the
# superproject tree identical and no cycle opens — and because the fingerprint
# is still non-empty, the caller does not fall back to the dirty-tree predicate
SUBT="$(mktemp -d "${TMPDIR:-/tmp}/cc-sub.XXXXXX")"
( git init -q -b main "$SUBT/lib" >/dev/null 2>&1
  cd "$SUBT/lib" && git config user.email t@t.t && git config user.name t \
    && echo lib > lib.txt && git add -A && git commit -qm init ) >/dev/null 2>&1
( git init -q -b main "$SUBT/lib2" >/dev/null 2>&1
  cd "$SUBT/lib2" && git config user.email t@t.t && git config user.name t \
    && echo lib2 > lib2.txt && git add -A && git commit -qm init ) >/dev/null 2>&1
# Holds a plan document AND unrelated content, so a scoped run mounted over it
# can be shown to distinguish the two.
( git init -q -b main "$SUBT/docsrepo" >/dev/null 2>&1
  cd "$SUBT/docsrepo" && git config user.email t@t.t && git config user.name t \
    && mkdir -p plans && echo "# plan" > plans/p.md && echo "api reference" > reference.md \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
if ( cd "$T" && git -c protocol.file.allow=always submodule add -q "$SUBT/lib" vendor ) >/dev/null 2>&1; then
  git commit -qm "add submodule" >/dev/null 2>&1
  S_CLEAN="$(fp_now)"
  echo "edited inside the submodule" >> vendor/lib.txt
  S_DIRTY="$(fp_now)"
  [[ "$S_DIRTY" != "$S_CLEAN" ]] && ok "an edit inside a submodule moves the fingerprint" || bad "submodule edit invisible — no cycle would open"
  echo "edited again" >> vendor/lib.txt
  [[ "$(fp_now)" != "$S_DIRTY" ]] && ok "a further edit is distinguishable" || bad "successive submodule edits collapse"
  git -C vendor checkout -q -- lib.txt
  [[ "$(fp_now)" == "$S_CLEAN" ]] && ok "reverting returns to the clean fingerprint" || bad "unstable across a revert"
  echo untracked > vendor/new.txt
  [[ "$(fp_now)" != "$S_CLEAN" ]] && ok "an untracked file inside a submodule counts too" || bad "untracked submodule content invisible"
  rm -f vendor/new.txt

  # A submodule inside a submodule. The recursion ran the child with
  # `GIT_INDEX_FILE=` — empty, which git reads as a literal index path rather
  # than as "unset" — so the child probed an EMPTY index, saw no gitlinks, and
  # folded the inner one in as unchanged.
  if ( cd "$SUBT/lib" && git -c protocol.file.allow=always submodule add -q "$SUBT/lib2" inner ) >/dev/null 2>&1 \
     && ( cd "$SUBT/lib" && git commit -qm "add inner" ) >/dev/null 2>&1 \
     && ( cd "$T/vendor" && git -c protocol.file.allow=always submodule update -q --init --recursive ) >/dev/null 2>&1; then
    git -C vendor pull -q origin main >/dev/null 2>&1 || git -C vendor fetch -q origin >/dev/null 2>&1
    ( cd "$T/vendor" && git -c protocol.file.allow=always submodule update -q --init --recursive ) >/dev/null 2>&1
    if [[ -d "$T/vendor/inner" ]]; then
      N_CLEAN="$(fp_now)"
      echo "edited two levels down" >> "$T/vendor/inner/lib2.txt"
      [[ "$(fp_now)" != "$N_CLEAN" ]] && ok "an edit inside a NESTED submodule moves the fingerprint" || bad "nested submodule content invisible"
      git -C "$T/vendor/inner" checkout -q -- lib2.txt 2>/dev/null
    else
      skip "nested submodule did not materialise — that coverage did NOT run"
    fi
  else
    skip "nested submodule fixture unavailable — that coverage did NOT run"
  fi

  # submodule.<name>.ignore exists to keep `git status` quiet, which is exactly
  # why a gate must not honour it: with `all`, a modified submodule produces no
  # porcelain output and the script returned a confident unchanged hash.
  for _ig in dirty all untracked; do
    git config "submodule.vendor.ignore" "$_ig"
    IG_CLEAN="$(fp_now)"
    echo "edited under ignore=$_ig" >> vendor/lib.txt
    [[ "$(fp_now)" != "$IG_CLEAN" ]] && ok "submodule.ignore=$_ig does not hide dirty content" || bad "submodule.ignore=$_ig hid a dirty submodule"
    git -C vendor checkout -q -- lib.txt
  done
  git config --unset submodule.vendor.ignore

  # Detection failure must yield NO fingerprint. Read through a pipeline, the
  # script reported the PARSER's status and returned the same confident hash
  # before and after a dirty child edit — a fabricated answer, worse than the
  # gate degrading to the dirty-tree predicate.
  REALGIT="$(command -v git)"
  STUBG="$T/stub-git"; mkdir -p "$STUBG"
  { echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do [ "$a" = "diff-files" ] && exit 128; done'
    echo "exec \"$REALGIT\" \"\$@\""
  } > "$STUBG/git"
  chmod +x "$STUBG/git"
  BROKEN="$(PATH="$STUBG:$PATH" bash "$FPSH")"
  [[ -z "$BROKEN" ]] && ok "a failing submodule probe yields no fingerprint (fail open)" || bad "fabricated a hash despite a failed probe: $BROKEN"

  git submodule deinit -qf vendor >/dev/null 2>&1; git rm -qf vendor >/dev/null 2>&1
  rm -rf .gitmodules .git/modules/vendor
  git add -A >/dev/null 2>&1; git commit -qm "drop submodule" >/dev/null 2>&1

  # A path with a space was word-split by the old `-- $SUB_PATHS` and silently
  # dropped, so edits inside it were invisible while the fingerprint stayed
  # confidently non-empty.
  if ( cd "$T" && git -c protocol.file.allow=always submodule add -q "$SUBT/lib" 'vendor lib' ) >/dev/null 2>&1; then
    git commit -qm "add spaced submodule" >/dev/null 2>&1
    W_CLEAN="$(fp_now)"
    echo "edited" >> 'vendor lib/lib.txt'
    [[ "$(fp_now)" != "$W_CLEAN" ]] && ok "a submodule path containing a space is still seen" || bad "spaced submodule path dropped by word-splitting"
    git submodule deinit -qf 'vendor lib' >/dev/null 2>&1; git rm -qf 'vendor lib' >/dev/null 2>&1
    rm -rf .gitmodules ".git/modules/vendor lib"
    git add -A >/dev/null 2>&1; git commit -qm "drop spaced submodule" >/dev/null 2>&1
  else
    skip "spaced-path submodule fixture unavailable — that coverage did NOT run"
  fi

  # Scoped (autoplan) mode used to skip submodules entirely, so a plan document
  # living in a submodule under docs/plans could never open a plan cycle.
  mkdir -p docs
  if ( cd "$T" && git -c protocol.file.allow=always submodule add -q "$SUBT/lib" docs/plans ) >/dev/null 2>&1; then
    git commit -qm "add plan submodule" >/dev/null 2>&1
    P_CLEAN="$(fp_now docs/plans docs/PLANS)"
    echo "plan edit" >> docs/plans/lib.txt
    [[ "$(fp_now docs/plans docs/PLANS)" != "$P_CLEAN" ]] && ok "a dirty submodule inside the plan scope moves the scoped fingerprint" || bad "scoped mode still blind to submodule content"
    git submodule deinit -qf docs/plans >/dev/null 2>&1; git rm -qf docs/plans >/dev/null 2>&1
    rm -rf .gitmodules .git/modules/docs
    git add -A >/dev/null 2>&1; git commit -qm "drop plan submodule" >/dev/null 2>&1
  else
    skip "scoped submodule fixture unavailable — that coverage did NOT run"
  fi
  rm -rf docs

  # The OTHER direction: the scoped path lives INSIDE a submodule. Folding the
  # submodule in whole made any edit anywhere in it move the plan fingerprint,
  # so the hook demanded a paid plan round for a change that touched no plan
  # document — while dirty_plans() (`git status -- docs/plans`) saw nothing.
  if ( cd "$T" && git -c protocol.file.allow=always submodule add -q "$SUBT/docsrepo" docs ) >/dev/null 2>&1; then
    git commit -qm "add docs submodule" >/dev/null 2>&1
    D_CLEAN="$(fp_now docs/plans docs/PLANS)"
    echo "an API note, not a plan" >> docs/reference.md
    [[ "$(fp_now docs/plans docs/PLANS)" == "$D_CLEAN" ]] \
      && ok "an out-of-scope edit inside a submodule leaves the scoped fingerprint alone" \
      || bad "the whole submodule was folded into the plan scope"
    echo "a real plan edit" >> docs/plans/p.md
    [[ "$(fp_now docs/plans docs/PLANS)" != "$D_CLEAN" ]] \
      && ok "and an in-scope edit inside it still moves the scoped fingerprint" \
      || bad "the scoped pathspec was not carried into the submodule"
    git submodule deinit -qf docs >/dev/null 2>&1; git rm -qf docs >/dev/null 2>&1
    rm -rf .gitmodules .git/modules/docs
    git add -A >/dev/null 2>&1; git commit -qm "drop docs submodule" >/dev/null 2>&1
  else
    skip "scope-inside-submodule fixture unavailable — that coverage did NOT run"
  fi
  rm -rf docs

  # A submodule whose worktree DIRECTORY is gone (removal not committed yet):
  # `cd` into it fails, and aborting the whole run there disabled the cycle
  # model for both gates until the removal was committed — the exact "commit
  # makes the gate go quiet" degradation the fingerprint exists to remove.
  if ( cd "$T" && git -c protocol.file.allow=always submodule add -q "$SUBT/lib" gone ) >/dev/null 2>&1; then
    git commit -qm "add doomed submodule" >/dev/null 2>&1
    G_CLEAN="$(fp_now)"
    rm -rf gone
    G_GONE="$(fp_now)"
    [[ -n "$G_GONE" ]] && ok "a deleted submodule does not abort the fingerprint" \
      || bad "removing a submodule silently disabled the cycle model"
    [[ "$G_GONE" != "$G_CLEAN" ]] && ok "and the removal itself is visible in it" \
      || bad "the deletion left the fingerprint unchanged"
    git submodule deinit -qf gone >/dev/null 2>&1; git rm -qf gone >/dev/null 2>&1
    rm -rf .gitmodules .git/modules/gone
    git add -A >/dev/null 2>&1; git commit -qm "drop doomed submodule" >/dev/null 2>&1
  else
    skip "deleted-submodule fixture unavailable — that coverage did NOT run"
  fi
else
  skip "submodule fixtures unavailable — ELEVEN dirty-submodule assertions did NOT run"
fi
rm -rf "$SUBT"

echo "== fingerprint: a failing pathspec is NOT an empty scope =="
# `git ls-files … | head` reports HEAD's status, so an invalid pathspec (git
# exits 128) read as "matches nothing" and the script returned the empty-tree
# hash — a stable value autoplan would treat as "no plan docs" forever.
[[ -z "$(fp_now ':(invalidmagic)x')" ]] \
  && ok "an invalid pathspec yields nothing (caller fails open)" \
  || bad "invalid pathspec returned a confident hash: $(fp_now ':(invalidmagic)x')"
[[ -n "$(fp_now docs/plans docs/PLANS)" ]] \
  && ok "absent-but-valid paths still yield the empty-tree hash" || bad "valid absent paths returned nothing"

echo "== fingerprint: the state dir is excluded even when NOT gitignored =="
# The add cannot name the state dir in a pathspec (git exits 1 when a pathspec
# names an ignored path, which is the normal case), so it is dropped from the
# throwaway index instead — which also covers a repo that never ignored it.
mkdir -p "$SD"
# The developer's GLOBAL gitignore also covers .claude/codex-threads, so moving
# the repo .gitignore aside is not enough — without neutralising core.excludesFile
if [[ -f .gitignore ]]; then mv .gitignore .gitignore.bak; fi
GLOBAL_EX="$(git config --get core.excludesFile || true)"
git config core.excludesFile /dev/null
echo tracked-state > "$SD/tracked.log"
FP_S1="$(fp_now)"
echo more >> "$SD/tracked.log"
[[ "$(fp_now)" == "$FP_S1" ]] && ok "un-ignored state-dir writes still excluded" || bad "state dir leaked when not gitignored"
rm -f "$SD/tracked.log"
if [[ -n "$GLOBAL_EX" ]]; then git config core.excludesFile "$GLOBAL_EX"; else git config --unset core.excludesFile || true; fi
if [[ -f .gitignore.bak ]]; then mv .gitignore.bak .gitignore; fi

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

echo "== a missing fingerprint script degrades to the dirty-tree test, loudly =="
# The stderr note says the gate "falls back to the dirty-tree test". It has to
# actually do that: disabling the gate while telling the user it is running in
# a weakened mode is worse than either honest option.
BASE="$(fp_now)"
arm_review_fp main review-main 3 0 0 "$BASE"
echo unreviewed >> f.txt
expect_block "precondition: blocks while the script is present"
HOOK_DIR="$(dirname "$HOOK")"; mv "$HOOK_DIR/../scripts/gate-fingerprint.sh" "$T/fp.bak"
expect_block "no fingerprint script -> still gates, via the legacy dirty test"
grep -q "gate-fingerprint.sh not found" "$ERR" && ok "loud warning names the missing script" || bad "silent fallback"
git add -A >/dev/null && git commit -qm "clean for the degraded-mode check"
expect_allow "degraded mode allows a clean tree (documented weaker guarantee)"
mv "$T/fp.bak" "$HOOK_DIR/../scripts/gate-fingerprint.sh"
rm -f "$SD/autoreview.armed"
git add -A >/dev/null && git commit -qm "settle 2" >/dev/null 2>&1

echo "== a verdict landing outside an open cycle does not bank =="
# THE hole a code review found. With no cycle open the hook used to exit
# without advancing the offset, so an APPROVE appended in that window sat past
# the cut and released the NEXT cycle for free.
git add -A >/dev/null && git commit -qm "settle before bank test" >/dev/null 2>&1
: > "$SD/review-main.log"
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "work" >> f.txt
expect_block "cycle 1 opens"
reply_log APPROVE
expect_allow "cycle 1 releases"
# Now an extra round arrives while nothing is open — /reply, a re-review, a
# stray dispatch. It answers no open cycle and must not be spendable later.
printf 'REPLY:\n  APPROVE\n---\nREPLY:\n  APPROVE\n' > "$SD/review-main.log"
expect_allow "an idle extra APPROVE is allowed through (nothing is open)"
OFF="$(sed -n 's/^log_bytes_at_arming=//p' "$SD/autoreview.armed")"
[[ "$OFF" == "$(logsize "$SD/review-main.log")" ]] && ok "the idle verdict was consumed, not banked" || bad "offset stale at '$OFF' (log is $(logsize "$SD/review-main.log"))"
echo "brand new unreviewed code" >> f.txt
expect_block "the next cycle still needs its OWN review (was: released free)"

echo "== the /autoreview arming flow itself cannot leak the first change =="
# /autoreview on writes fp_at_arming and THEN reviews existing work, so that
# APPROVE lands while the fingerprint still equals fp_at_arming. That is the
# sequence which shipped the first genuinely new change ungated.
git add -A >/dev/null && git commit -qm "settle before arming-flow test" >/dev/null 2>&1
: > "$SD/review-main.log"
arm_review_fp main review-main 3 0 0 "$(fp_now)"     # armed on a clean tree
reply_log APPROVE                                     # the arming-time review
expect_allow "clean tree right after arming -> allow"
echo "first real change after arming" >> f.txt
expect_block "the first change after arming is gated (was: allowed)"

echo "== the released fingerprint belongs to the verdict that earned it =="
# Verdict and fingerprint chosen independently: an APPROVE for state A followed
# by a successful but verdict-less dispatch B released B. The driver stamps the
# pre-dispatch state into each record; the parser returns the verdict's own.
git add -A >/dev/null && git commit -qm "settle before correlation test" >/dev/null 2>&1
: > "$SD/review-main.log"
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "reviewed change" >> f.txt
FP_A="$(fp_now)"
printf '[t1] mode=initial thread=review-main round=1 fp=%s\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n' "$FP_A" > "$SD/review-main.log"
echo "added after the verdict, reviewed by nobody" >> f.txt
FP_B="$(fp_now)"
printf '[t2] mode=resume thread=review-main round=2 fp=%s\nPROMPT:\n  p\nREPLY:\n  prose, no verdict at all\n---\n' "$FP_B" >> "$SD/review-main.log"
printf '%s\n' "$FP_B" > "$SD/review-main.dispatch-fp"     # the sidecar the later dispatch overwrote
expect_block "state B is gated: the APPROVE judged A, not B"
[[ "$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")" == "$FP_A" ]] \
  && ok "released_fp is the state the verdict actually judged" || bad "released_fp took the later dispatch's state"
# A record written before headers carried fp= must keep working, falling back to
# the sidecar rather than blocking an existing thread forever.
: > "$SD/review-main.log"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "legacy-era change" >> f.txt
printf '%s\n' "$(fp_now)" > "$SD/review-main.dispatch-fp"
printf '[t1] mode=initial thread=review-main round=1\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n' > "$SD/review-main.log"
expect_allow "a pre-fp= record still releases via the sidecar"
rm -f "$SD/autoreview.armed" "$SD/review-main.dispatch-fp"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

# …but that fallback is only sound while the legacy record is the LAST one: a
# later dispatch owns the sidecar, so the APPROVE cannot be attributed at all.
: > "$SD/review-main.log"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "legacy-era change" >> f.txt
printf '[t1] mode=initial thread=review-main round=1\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n' > "$SD/review-main.log"
echo "written after, reviewed by nobody" >> f.txt
printf '[t2] mode=resume thread=review-main round=2 fp=%s\nPROMPT:\n  p\nREPLY:\n  prose, no verdict\n---\n' "$(fp_now)" >> "$SD/review-main.log"
printf '%s\n' "$(fp_now)" > "$SD/review-main.dispatch-fp"   # overwritten by that later dispatch
expect_block "an unattributable legacy APPROVE does not release"
grep -q "cannot be established" "$ERR" && ok "and says why it refused" || bad "no explanation for the refusal"
[[ -z "$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")" ]] \
  && ok "and records no release" || bad "released_fp written for an unattributable APPROVE"
rm -f "$SD/autoreview.armed" "$SD/review-main.dispatch-fp" "$SD/review-main.log"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== release records what CODEX saw, not the tree at turn-end =="
# Code written after the verdict arrives but before the turn ends was never
# reviewed. Releasing against the driver's dispatch-time snapshot keeps it
# gated; releasing against the worktree at Stop would stamp it approved.
git add -A >/dev/null && git commit -qm "settle before dispatch-fp test" >/dev/null 2>&1
: > "$SD/review-main.log"
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "reviewed change" >> f.txt
expect_block "cycle opens"
printf '%s\n' "$(fp_now)" > "$SD/review-main.dispatch-fp"   # what the driver snapshots
reply_log APPROVE
echo "snuck in after the verdict" >> f.txt                  # never reviewed
# The release covers the state Codex saw. Since the worktree has already moved
# past it, the next cycle is open ALREADY — blocking now rather than letting
# this turn end and catching it only if there happens to be another one.
expect_block "code added after the verdict opens the next cycle at once"
expect_block "and it stays open on the following turn"
rm -f "$SD/review-main.dispatch-fp"
# An unreadable snapshot is not a licence to release the current tree: nothing
# records what was dispatched, so it must block — and must not DEADLOCK, which
# is what the old fallback avoided. The next dispatch settles it.
git add -A >/dev/null && git commit -qm "settle" >/dev/null 2>&1
: > "$SD/review-main.log"
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "x" >> f.txt; expect_block "cycle opens"
reply_log APPROVE
echo "not-a-fingerprint" > "$SD/review-main.dispatch-fp"   # after reply_log, which writes a good one
expect_block "an unreadable dispatch-fp does not release the current tree"
grep -q "cannot be tied to a dispatched state" "$ERR" && ok "and says the state cannot be established" || bad "no explanation for the refusal"
[[ -z "$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")" ]] && ok "and records no release" || bad "released_fp written from an unreadable snapshot"
printf '%s\n' "$(fp_now)" > "$SD/review-main.dispatch-fp"  # the next dispatch snapshots properly
expect_allow "the next dispatch settles it — refusing is a round, not a deadlock"
rm -f "$SD/review-main.dispatch-fp" "$SD/autoreview.armed"
git add -A >/dev/null && git commit -qm "settle" >/dev/null 2>&1

echo "== neither gate releases state that was never dispatched =="
# The attack in one line: review state A, lose every record of what was
# dispatched, edit to B before the turn ends — and B is stamped approved though
# nothing ever looked at it. Both gates must refuse.
git add -A >/dev/null && git commit -qm "settle before never-dispatched test" >/dev/null 2>&1
: > "$SD/review-main.log"
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "state A" >> f.txt; expect_block "cycle opens on A"
printf 'REPLY:\n  APPROVE\n---\n' > "$SD/review-main.log"    # a verdict with NO record of its state
echo "state B, written after the verdict" >> f.txt
expect_block "autoreview refuses to release B on a verdict that named no state"
[[ -z "$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")" ]] \
  && ok "and B is not recorded as approved" || bad "B stamped approved: $(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")"
rm -f "$SD/autoreview.armed" "$SD/review-main.log"
git checkout -q -- f.txt 2>/dev/null; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

rm -rf docs; mkdir -p docs/plans; echo "# plan A" > docs/plans/p.md
git add -A >/dev/null && git commit -qm "plan A" >/dev/null 2>&1
: > "$SD/plan-main.log"
arm_plan_fp main plan-main 3 0 0 "$(fp_now docs/plans docs/PLANS)"
echo "# edited" >> docs/plans/p.md; expect_block "plan cycle opens"
printf 'REPLY:\n  stress-tested\n' > "$SD/plan-main.log"     # growth with NO record of its state
echo "# plan B, written after the dispatch" >> docs/plans/p.md
expect_block "autoplan refuses to release a plan state nothing recorded"
[[ -z "$(sed -n 's/^released_fp=//p' "$SD/autoplan.armed")" ]] \
  && ok "and the plan is not recorded as stress-tested" || bad "plan B stamped released"
rm -f "$SD/autoplan.armed" "$SD/plan-main.log"; rm -rf docs
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== a pre-0.9 armed file adopts the cycle model at its FIRST release =="
# The compatibility promise is "keeps the old behaviour UNTIL its first
# release", not "forever". The old test only exercised clean/dirty/commit and
: > "$SD/review-main.log"
arm_review main review-main 3 0 0        # legacy: no fp_at_arming
echo legacy-work >> f.txt
expect_block "legacy file blocks on a dirty tree"
reply_log APPROVE
expect_allow "legacy file releases on APPROVE"
[[ -n "$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")" ]] \
  && ok "released_fp now present: it has joined the cycle model" \
  || bad "legacy file did not adopt the cycle model on release"
echo "post-release code" >> f.txt
expect_block "and it now gates new code like a 0.9 gate"
rm -f "$SD/autoreview.armed"
git add -A >/dev/null && git commit -qm "settle" >/dev/null 2>&1

echo "== the round budget survives revert-and-reapply =="
# Idle consumption used to call rebaseline_cycle, which resets blocks=0. So:
# burn the cap, revert to the released state, let the idle pass consume, reapply
# the change — and get a full budget again, repeatably. The cap bounded nothing.
git add -A >/dev/null && git commit -qm "settle before budget test" >/dev/null 2>&1
: > "$SD/review-main.log"
BASE_FP="$(fp_now)"
arm_review_fp main review-main 2 0 0 "$BASE_FP"
reply_log REQUEST_CHANGES
# The backup lives OUTSIDE the repo: the fingerprint hashes untracked content,
# so a copy kept inside is itself a change and the "revert" never returns to the
# baseline — which made the assertion below unable to fail.
ORIG="$(mktemp "${TMPDIR:-/tmp}/cc-hook-orig.XXXXXX")"
cp f.txt "$ORIG"
echo "risky" >> f.txt
expect_block "budget 1/2"
expect_block "budget 2/2"
expect_allow "cap reached"
cp "$ORIG" f.txt                            # back to the released state
printf 'REPLY:\n  REQUEST_CHANGES\n---\nREPLY:\n  REQUEST_CHANGES\n' > "$SD/review-main.log"   # log grows while idle
run_hook                                    # the idle pass runs here
[[ "$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")" != "0" ]] \
  && ok "idle consumption did not refill the round budget" \
  || bad "budget refilled without an earned release — the cap can be reset indefinitely"
echo "risky again" >> f.txt
expect_allow "still capped after revert-and-reapply"
rm -f "$SD/autoreview.armed"; cp "$ORIG" f.txt; rm -f "$ORIG"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== a pre-0.9 armed file does not bank idle verdicts either =="
# Its fingerprint fields stay absent (dirty-tree predicate still governs it),
# but an APPROVE arriving while clean must not sit past the cut and release the
# next dirty state.
: > "$SD/review-main.log"
arm_review main review-main 3 0 0            # legacy: no fp_at_arming
reply_log APPROVE                            # lands while the tree is clean
expect_allow "clean tree, legacy file -> allow"
[[ "$(sed -n 's/^log_bytes_at_arming=//p' "$SD/autoreview.armed")" == "$(logsize "$SD/review-main.log")" ]] \
  && ok "the idle APPROVE was consumed on the legacy path too" || bad "legacy file banked the verdict"
[[ -z "$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")" ]] \
  && ok "and it did NOT silently adopt the cycle model" || bad "legacy file gained a fingerprint from an idle pass"
echo "now dirty" >> f.txt
expect_block "the banked APPROVE cannot release the next dirty state"
rm -f "$SD/autoreview.armed"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== concurrent hooks cannot corrupt the armed file =="
# Every writer used a shared "$f.tmp", so one hook truncated it while another's
# `grep -v` was still reading. Twenty parallel hooks left the file as the single
# line `blocks=1` — branch, thread and cap GONE, i.e. a silently and permanently
# disarmed gate. A lost increment only delays the cap; corruption removes it.
git add -A >/dev/null && git commit -qm "settle before race test" >/dev/null 2>&1
: > "$SD/review-main.log"
arm_review_fp main review-main 50 0 0 "$(fp_now)"
echo "concurrent work" >> f.txt
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  ( printf '%s' "$DEFAULT_INPUT" | bash "$HOOK" >/dev/null 2>&1 ) &
done
wait
for k in branch thread lens cap blocks log_bytes_at_arming fp_at_arming; do
  grep -q "^$k=" "$SD/autoreview.armed" || { bad "field '$k' lost to the race"; break; }
done
grep -q '^branch=' "$SD/autoreview.armed" && grep -q '^cap=' "$SD/autoreview.armed" && grep -q '^fp_at_arming=' "$SD/autoreview.armed" \
  && ok "the armed file survives 20 concurrent hooks intact" || bad "armed file corrupted by concurrent hooks"
# And no LOST increments: the rename alone kept the file valid but let twenty
# blocks count as one, so the cap arrived twenty times later than it should.
RACED="$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")"
[[ "$RACED" == "20" ]] && ok "all 20 blocks counted (no lost increments)" || bad "only $RACED of 20 blocks counted — the cap is not what it says"
[[ -z "$(ls -d "$SD"/autoreview.armed.lock 2>/dev/null)" ]] && ok "no lock left behind" || bad "stale lock survives"
[[ -z "$(ls "$SD"/autoreview.armed.[A-Za-z0-9]* 2>/dev/null | grep -v '\.lock$')" ]] && ok "no temp files left behind" || bad "leftover rewrite temp files"
rm -f "$SD/autoreview.armed"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== all THREE armed-state writers refuse to write without the lock =="
# The 20-way race above only exercises bump_blocks; the other two writers
# rewrite the whole file too. Holding the lock from outside is the deterministic
# form of that race — each writer must decline rather than write anyway. The
# lock is fresh, so the stale-steal path is not involved.
git add -A >/dev/null && git commit -qm "settle before lock test" >/dev/null 2>&1
: > "$SD/review-main.log"
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "work needing review" >> f.txt
mkdir -p "$SD/autoreview.armed.lock"
expect_allow "a block whose counter cannot be locked fails open"
grep -q "could not persist the blocks counter" "$ERR" && ok "and says the counter was not persisted" || bad "no counter diagnostic"
[[ "$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")" == "0" ]] \
  && ok "bump_blocks wrote nothing while locked out" || bad "blocks advanced without the lock"

# The release path, locked out: nothing recorded, and it says so.
printf '[t1] mode=initial thread=review-main round=1 fp=%s\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n' "$(fp_now)" > "$SD/review-main.log"
expect_allow "an APPROVE still ends the turn when the lock is unavailable"
grep -q "lock could not be acquired" "$ERR" && ok "and the unrecorded release is reported" || bad "release lock failure was silent"
[[ -z "$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")" ]] \
  && ok "rebaseline_cycle wrote nothing while locked out" || bad "released_fp written without the lock"

# Idle consumption, locked out: the cut must not move.
rm -f "$SD/autoreview.armed"
git checkout -q -- f.txt 2>/dev/null; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1
arm_review_fp main review-main 3 0 0 "$(fp_now)"
mkdir -p "$SD/autoreview.armed.lock"
printf 'REPLY:\n  APPROVE\n---\n' >> "$SD/review-main.log"     # growth with no cycle open
expect_allow "an idle turn allows regardless"
[[ "$(sed -n 's/^log_bytes_at_arming=//p' "$SD/autoreview.armed")" == "0" ]] \
  && ok "idle consumption wrote nothing while locked out" || bad "the cut advanced without the lock"
rm -rf "$SD/autoreview.armed.lock"
rm -f "$SD/autoreview.armed" "$SD/review-main.log"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== releasing a lock we do not own is refused =="
# The stale-steal guard cannot help against the ORIGINAL owner: a holder that
# stalls past the window gets its lock stolen and replaced, and on resuming
# would delete the REPLACEMENT owner's lock with an unconditional rm. A lock
# carrying somebody else's token must survive everything this hook does.
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "work" >> f.txt
mkdir -p "$SD/autoreview.armed.lock"
printf 'someone-elses-token' > "$SD/autoreview.armed.lock/owner"
expect_allow "a foreign lock blocks the write and the turn ends"
[[ -d "$SD/autoreview.armed.lock" ]] && ok "the foreign lock still exists" || bad "deleted a lock this hook never owned"
[[ "$(cat "$SD/autoreview.armed.lock/owner" 2>/dev/null)" == "someone-elses-token" ]] \
  && ok "and its owner token is untouched" || bad "foreign owner token overwritten"
rm -rf "$SD/autoreview.armed.lock"; rm -f "$SD/autoreview.armed" "$SD/review-main.log"
git checkout -q -- f.txt 2>/dev/null; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

# The interleaving the token actually defends against: our lock is stolen and
# REPLACED while we hold it, and on releasing we must not delete the
# replacement. It cannot be produced by timing from outside, so it is injected
# at the post-lock seam — the same approach cleanup.sh uses for its re-check.
cat > "$T/steal-lock.sh" <<'STEAL'
d="$1.lock"
rm -rf "$d"; mkdir -p "$d"; printf 'replacement-owner' > "$d/owner"
STEAL
# The token stops the evicted holder DELETING the replacement's lock. It must
# also stop it WRITING: acquisition proves ownership then, not now, so every
# writer revalidates immediately before its rename.
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "work for the write-after-eviction test" >> f.txt
BEFORE_BLOCKS="$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")"
CC_STOP_TEST_POST_LOCK_HOOK="$T/steal-lock.sh" run_hook
[[ "$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")" == "$BEFORE_BLOCKS" ]] \
  && ok "a holder that lost the lock writes nothing" || bad "evicted holder still bumped the counter"
grep -q "could not persist the blocks counter" "$ERR" && ok "and reports the counter as unpersisted" || bad "silent write-after-eviction"
rm -rf "$SD/autoreview.armed.lock"; rm -f "$SD/autoreview.armed" "$SD/review-main.log"
git checkout -q -- f.txt 2>/dev/null; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "work for the steal test" >> f.txt
CC_STOP_TEST_POST_LOCK_HOOK="$T/steal-lock.sh" run_hook
[[ "$(cat "$SD/autoreview.armed.lock/owner" 2>/dev/null)" == "replacement-owner" ]] \
  && ok "a lock replaced under us survives our release" || bad "released a replacement owner's lock"
rm -rf "$SD/autoreview.armed.lock"; rm -f "$SD/autoreview.armed" "$SD/review-main.log"
git checkout -q -- f.txt 2>/dev/null; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== arming and disarming go through the same mutex as the hook =="
# They rewrite the same whole file the hook's three writers do. Straight from a
# command snippet they were outside the mutex, so a turn-end hook could
# overwrite a fresh arming with the previous cycle's counters, or put back a
# gate the user had just switched off.
GSH="$(cd "$(dirname "$HOOK")/../scripts" && pwd)/gate-state.sh"
AF="$SD/gs-test.armed"
rm -f "$AF"; rm -rf "$AF.lock"
printf 'branch=main\nthread=t\ncap=3\n' | bash "$GSH" write "$AF" >/dev/null 2>&1
[[ "$(sed -n 's/^cap=//p' "$AF" 2>/dev/null)" == "3" ]] && ok "write creates the armed file" || bad "gate-state write did not land"
mkdir -p "$AF.lock"; printf 'held-elsewhere' > "$AF.lock/owner"
printf 'branch=main\nthread=t\ncap=99\n' | bash "$GSH" write "$AF" >/dev/null 2>&1; GRC=$?
[[ "$GRC" -eq 2 ]] && ok "a locked-out write exits 2" || bad "locked-out write rc=$GRC"
[[ "$(sed -n 's/^cap=//p' "$AF" 2>/dev/null)" == "3" ]] && ok "and the previous state is intact" || bad "armed file overwritten without the lock"
bash "$GSH" remove "$AF" >/dev/null 2>&1; GRC=$?
[[ "$GRC" -eq 2 && -f "$AF" ]] && ok "a locked-out remove exits 2 and disarms nothing" || bad "removed the armed file without the lock (rc=$GRC)"
[[ "$(cat "$AF.lock/owner" 2>/dev/null)" == "held-elsewhere" ]] && ok "and the foreign lock is left alone" || bad "gate-state released a lock it did not own"
rm -rf "$AF.lock"
bash "$GSH" remove "$AF" >/dev/null 2>&1
[[ ! -f "$AF" ]] && ok "remove disarms once the lock is free" || bad "gate-state remove did not disarm"
[[ -z "$(ls -d "$AF".* 2>/dev/null)" ]] && ok "and leaves no lock or temp behind" || bad "gate-state leftovers: $(ls -d "$AF".* 2>/dev/null)"

echo "== a stale lock is stolen, but only the one that was measured stale =="
# A blind `rm -rf` deleted whatever was there, so a writer preempted between the
# age check and the removal came back and deleted the REPLACEMENT owner's fresh
# lock. An unchanged mtime is what identifies the same lock.
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "work for the stale-lock test" >> f.txt
mkdir -p "$SD/autoreview.armed.lock"
touch -t 200001010000 "$SD/autoreview.armed.lock" 2>/dev/null || touch -d '2000-01-01' "$SD/autoreview.armed.lock" 2>/dev/null
expect_block "a lock older than 30s is stolen and the block proceeds"
[[ "$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")" == "1" ]] \
  && ok "and the increment landed" || bad "stale lock was not reclaimed"
rm -rf "$SD/autoreview.armed.lock"; rm -f "$SD/autoreview.armed" "$SD/review-main.log"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== counters too large for shell arithmetic fail OPEN =="
# There must be WORK, or the gate allows for the ordinary reason and the
# assertion cannot fail. bash wraps silently here: 0 -ge 99999999999999999999
# is FALSE and (off + 1) yields 7766279631452241920, so an unbounded cap means
# the block counter never reaches it — unbounded blocking, not a failure.
echo "work for the counter test" >> f.txt
arm_review main review-main 99999999999999999999 0 0
expect_allow "a 20-digit cap fails open rather than blocking forever"
grep -q "malformed" "$ERR" && ok "and says why" || bad "no malformed-counter note"
arm_review main review-main 3 0 99999999999999999999
expect_allow "a 20-digit log offset fails open"
rm -f "$SD/autoreview.armed"
git add -A >/dev/null && git commit -qm "settle after counter test" >/dev/null 2>&1

echo "== BOTH gates armed: a block on one must not bank the other's verdicts =="
# emit_block and allow exit the whole hook, so a block on autoreview used to
# skip autoplan entirely — including its idle-verdict consumption. Plan-thread
# growth during the blocked turn then banked and released the next plan cycle
git add -A >/dev/null && git commit -qm "settle before two-gate test" >/dev/null 2>&1
rm -rf docs; mkdir -p docs/plans
: > "$SD/review-main.log"; : > "$SD/plan-main.log"
arm_review_fp main review-main 3 0 0 "$(fp_now)"
arm_plan_fp   main plan-main   2 0 0 "$(fp_now docs/plans docs/PLANS)"
echo "code" >> f.txt                                   # opens the autoreview cycle only
printf 'REPLY:\n  chatter, not a stress-test\n' > "$SD/plan-main.log"   # plan thread grows
expect_block "turn 1: autoreview blocks (plans untouched)"
AP_OFF="$(sed -n 's/^log_bytes_at_arming=//p' "$SD/autoplan.armed")"
[[ "$AP_OFF" == "$(logsize "$SD/plan-main.log")" ]] \
  && ok "autoplan consumed its idle growth despite the autoreview block" \
  || bad "autoplan growth banked while the other gate blocked (off=$AP_OFF log=$(logsize "$SD/plan-main.log"))"
reply_log APPROVE                                       # release autoreview
echo "# brand new, never stress-tested" > docs/plans/new.md
expect_block "turn 2: the new plan doc still needs its OWN dispatch"
# Remove the thread logs too: the next block arms with log_bytes_at_arming=0,
# and a log left behind here would read as "already dispatched" and release it.
rm -f "$SD/autoreview.armed" "$SD/autoplan.armed" "$SD/plan-main.log" "$SD/review-main.log"; rm -rf docs
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== autoplan releases against the PLAN-scoped snapshot, not the whole tree =="
# The driver writes both sidecars; the hook must pick the plan one. Comparing a
# whole-tree hash against a pathspec hash can never be equal, so the gate
# re-blocked immediately after every release, all the way to the cap. The
# earlier tests wrote NO sidecar and so only exercised the fallback.
git add -A >/dev/null && git commit -qm "settle before plan-scope test" >/dev/null 2>&1
rm -rf docs; mkdir -p docs/plans; echo "# p" > docs/plans/p.md
: > "$SD/plan-main.log"
arm_plan_fp main plan-main 3 0 0 "$(fp_now docs/plans docs/PLANS)"
echo "# edited" >> docs/plans/p.md
expect_block "plan edit opens the cycle"
printf '%s\n' "$(fp_now)"                        > "$SD/plan-main.dispatch-fp"       # whole tree
printf '%s\n' "$(fp_now docs/plans docs/PLANS)"  > "$SD/plan-main.dispatch-fp-plan"  # plan scope
printf 'REPLY:\n  stress-tested\n' > "$SD/plan-main.log"
expect_allow "the dispatch released the plan state it saw"
[[ "$(sed -n 's/^released_fp=//p' "$SD/autoplan.armed")" == "$(fp_now docs/plans docs/PLANS)" ]] \
  && ok "released_fp is the PLAN-scoped hash" || bad "released_fp is not the plan hash — the whole-tree one leaked in"
expect_allow "and it stays released while the plan is unchanged"
echo "# edited again after the dispatch" >> docs/plans/p.md
expect_block "a plan edit made after the dispatch is not covered by it"
rm -f "$SD/autoplan.armed" "$SD/plan-main.dispatch-fp" "$SD/plan-main.dispatch-fp-plan" "$SD/plan-main.log"
rm -rf docs; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== autoplan releases the LATEST dispatch's plan state, not the verdict's =="
# The plan gate releases on log GROWTH, so its releasing dispatch is the most
# recent one and need not carry a verdict. Taking the last VERDICT's record
# released an older state and re-blocked the current plan, every turn, to the cap.
git add -A >/dev/null && git commit -qm "settle before latest-plan test" >/dev/null 2>&1
rm -rf docs; mkdir -p docs/plans; echo "# p" > docs/plans/p.md
: > "$SD/plan-main.log"
arm_plan_fp main plan-main 3 0 0 "$(fp_now docs/plans docs/PLANS)"
echo "# edited" >> docs/plans/p.md
expect_block "plan edit opens the cycle"
PLAN_A="$(fp_now docs/plans docs/PLANS)"
printf '[t1] mode=initial thread=plan-main round=1 fp-plan=%s\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n' "$PLAN_A" > "$SD/plan-main.log"
echo "# edited again, then dispatched again without a verdict" >> docs/plans/p.md
PLAN_B="$(fp_now docs/plans docs/PLANS)"
printf '[t2] mode=resume thread=plan-main round=2 fp-plan=%s\nPROMPT:\n  p\nREPLY:\n  further objections, no verdict line\n---\n' "$PLAN_B" >> "$SD/plan-main.log"
expect_allow "the latest dispatch releases the plan state IT saw"
[[ "$(sed -n 's/^released_fp=//p' "$SD/autoplan.armed")" == "$PLAN_B" ]] \
  && ok "released_fp is the latest dispatch's plan hash" || bad "released_fp came from the APPROVE's older record"
expect_allow "and the released plan stays released"
rm -f "$SD/autoplan.armed" "$SD/plan-main.log"
rm -rf docs; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== an idle-consumed verdict is not re-spent after a rotation =="
# The cut is a PAIR: byte offset and rotation generation. Advancing only the
# offset left the generation stale, so the next rotation reset the offset to 0
# and the consumed APPROVE released a cycle it had already answered — and with
# the fingerprint unavailable it ALLOWED the turn outright.
git add -A >/dev/null && git commit -qm "settle before re-spend test" >/dev/null 2>&1
rm -f "$SD/review-main.log-gen"
IDLE_FP="$(fp_now)"
printf '1\n' > "$SD/review-main.log-gen"                       # the driver rotated
printf '[t] mode=resume thread=review-main round=9 fp=%s\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n' "$IDLE_FP" > "$SD/review-main.log"
printf '%s\n' "$IDLE_FP" > "$SD/review-main.dispatch-fp"
arm_review_fp main review-main 3 0 0 "$IDLE_FP" 0               # armed at generation 0
expect_allow "an idle turn consumes the verdict"
[[ "$(sed -n 's/^log_gen_at_arming=//p' "$SD/autoreview.armed")" == "1" ]] \
  && ok "and records the generation it consumed at" || bad "idle consumption left the generation stale"
echo "brand new, reviewed by nobody" >> f.txt
expect_block "the consumed verdict cannot release the NEXT cycle"
[[ -z "$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")" ]] \
  && ok "and nothing is recorded as released" || bad "a re-spent verdict wrote released_fp"
rm -f "$SD/autoreview.armed" "$SD/review-main.log" "$SD/review-main.log-gen" "$SD/review-main.dispatch-fp"
git checkout -q -- f.txt 2>/dev/null; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== an EQUAL-SIZE rotation is still consumed, and the budget survives =="
# The early exit compared the byte offset alone, so a rotation whose replacement
# log happened to be exactly the stored size slipped through: the generation
# stayed stale, and the next open cycle reset the cut to zero and re-spent the
# verdict — repeatable, so revert/reapply kept refilling `blocks`.
git add -A >/dev/null && git commit -qm "settle before equal-size test" >/dev/null 2>&1
rm -f "$SD/review-main.log-gen"
EQ_FP="$(fp_now)"
printf '[t] mode=resume thread=review-main round=1 fp=%s\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n' "$EQ_FP" > "$SD/review-main.log"
EQ_SIZE="$(logsize "$SD/review-main.log")"
printf '%s\n' "$EQ_FP" > "$SD/review-main.dispatch-fp"
# Armed AT that size and generation 0 — then the driver rotates, and the
# replacement log is byte-for-byte the same length.
arm_review_fp main review-main 3 2 "$EQ_SIZE" "$EQ_FP" 0
printf '1\n' > "$SD/review-main.log-gen"
expect_allow "an idle turn with an equal-size rotation still allows"
[[ "$(sed -n 's/^log_gen_at_arming=//p' "$SD/autoreview.armed")" == "1" ]] \
  && ok "and the generation is consumed despite the identical byte count" || bad "equal-size rotation left the generation stale"
[[ "$(sed -n 's/^blocks=//p' "$SD/autoreview.armed")" == "2" ]] \
  && ok "and the round budget is untouched by an idle pass" || bad "idle consumption refilled blocks"
echo "new work nobody reviewed" >> f.txt
expect_block "the consumed verdict cannot release the cycle that opens next"
[[ -z "$(sed -n 's/^released_fp=//p' "$SD/autoreview.armed")" ]] \
  && ok "and nothing is recorded as released" || bad "a re-spent verdict wrote released_fp"
rm -f "$SD/autoreview.armed" "$SD/review-main.log" "$SD/review-main.log-gen" "$SD/review-main.dispatch-fp"
git checkout -q -- f.txt 2>/dev/null; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== rotation does not hide a verdict when the new log is not smaller =="
# The cut is a byte offset into the log as it WAS. Rotation makes it point into
# unrelated content, and the size test only notices when the replacement is
# smaller — so a rotated-in log of equal or greater size skipped every verdict
# before that offset until the cap released the cycle.
git add -A >/dev/null && git commit -qm "settle before rotation test" >/dev/null 2>&1
rm -f "$SD/review-main.log-gen"
BASE_FP="$(fp_now)"
echo "work needing review" >> f.txt
# A fresh log LARGER than the old cut, with the APPROVE before that byte.
# The APPROVE record carries its fp= exactly as a real dispatch stamps it —
# without it the refusal under test would be the unattributable one, not the cut.
{ printf '[t] mode=resume thread=review-main round=9 fp=%s\nPROMPT:\n  p\nREPLY:\n  APPROVE\n---\n' "$(fp_now)"
  i=1; while [ "$i" -le 40 ]; do printf '[t] mode=resume thread=review-main round=%s\nPROMPT:\n  filler\nREPLY:\n  chatter\n---\n' "$i"; i=$((i+1)); done
} > "$SD/review-main.log"
arm_review_fp main review-main 3 0 120 "$BASE_FP"       # cut at byte 120: past the APPROVE
expect_block "without a rotation, the cut still hides what precedes it"
printf '1\n' > "$SD/review-main.log-gen"               # the driver rotated since arming
expect_allow "a rotation makes the whole current log post-cut, and the verdict is seen"
[[ "$(sed -n 's/^log_gen_at_arming=//p' "$SD/autoreview.armed")" == "1" ]] \
  && ok "and the release records the generation it released at" || bad "log_gen_at_arming not recorded"
expect_allow "which does not re-trigger on the next turn"
rm -f "$SD/autoreview.armed" "$SD/review-main.log" "$SD/review-main.log-gen" "$SD/review-main.dispatch-fp"
git checkout -q -- f.txt 2>/dev/null; git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== /status keeps a plan-scope fallback when the script is missing =="
# Resolved solely by shelling out, an absent gate-fingerprint.sh left plan_paths
# empty and the status line became `git status -- ` — no pathspec at all — so
# every change in the tree was counted as a plan-doc change.
SSH_DIR="$T/status-only"; mkdir -p "$SSH_DIR"
cp "$(dirname "$HOOK")/../scripts/status.sh" "$(dirname "$HOOK")/../scripts/lib.sh" \
   "$(dirname "$HOOK")/../scripts/last-verdict.sh" "$SSH_DIR/"     # deliberately NO gate-fingerprint.sh
rm -rf docs; echo "a code change" >> f.txt
SOUT="$(bash "$SSH_DIR/status.sh" 2>/dev/null | grep 'working tree')"
printf '%s' "$SOUT" | grep -q '0 plan-doc change' \
  && ok "an absent fingerprint script does not turn every file into a plan doc" \
  || bad "plan-doc count without a fallback: $SOUT"
git checkout -q -- f.txt 2>/dev/null; rm -rf "$SSH_DIR"
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== the plan scope has ONE definition, and everything follows it =="
# The default lived in four files (hook, driver, /status, the arming command).
# A change that misses one leaves the dirt predicate and the fingerprint
# disagreeing about what a plan document IS — a gate that can never release.
rm -rf docs custom-plans; mkdir -p custom-plans docs/plans
git add -A >/dev/null && git commit -qm "settle before scope test" >/dev/null 2>&1
[[ "$(CC_CODEX_PLAN_PATHS='custom-plans' bash "$FPSH" --plan-paths)" == "custom-plans" ]] \
  && ok "the canonical script reports the configured scope" || bad "--plan-paths ignored CC_CODEX_PLAN_PATHS"
# BOTH scopes must hold content, and different content. With them empty every
# hash here is the empty-tree hash, so a --plan that ignored the env var and
# hardcoded docs/plans would still match — the drift this section exists to
# catch would ship green.
echo "# configured-scope doc" > custom-plans/p.md
echo "# default-scope doc" > docs/plans/d.md
CUSTOM_FP="$(CC_CODEX_PLAN_PATHS='custom-plans' bash "$FPSH" --plan)"
[[ "$CUSTOM_FP" == "$(CC_CODEX_PLAN_PATHS='custom-plans' bash "$FPSH" custom-plans)" ]] \
  && ok "--plan hashes exactly that scope" || bad "--plan and the explicit pathspec disagree"
[[ -n "$CUSTOM_FP" && "$CUSTOM_FP" != "$(bash "$FPSH" --plan)" ]] \
  && ok "and follows the configured scope rather than the default one" || bad "--plan ignored CC_CODEX_PLAN_PATHS"
rm -rf docs
git add -A >/dev/null && git commit -qm "settle scope fixture" >/dev/null 2>&1
: > "$SD/plan-main.log"
arm_plan_fp main plan-main 3 0 0 "$(CC_CODEX_PLAN_PATHS='custom-plans' bash "$FPSH" --plan)"
echo "# a plan doc in a NON-default location" > custom-plans/p.md
CC_CODEX_PLAN_PATHS='custom-plans' run_hook
[[ -n "$OUT" ]] && ok "the hook gates on the configured scope too" || bad "the hook ignored CC_CODEX_PLAN_PATHS (scope definitions have drifted)"
rm -f "$SD/autoplan.armed"
# And the legacy dirt predicate, which is a SEPARATE reader of the same scope —
# the fingerprint path above would pass even if it had its own hardcoded copy.
: > "$SD/plan-main.log"
arm_plan main plan-main 3 0 0
mkdir -p custom-plans; echo "# legacy-path plan doc" > custom-plans/p.md
CC_CODEX_PLAN_PATHS='custom-plans' run_hook
[[ -n "$OUT" ]] && ok "the dirt predicate follows the configured scope too" || bad "dirty_plans has its own copy of the scope"
rm -f "$SD/autoplan.armed" "$SD/plan-main.log"; rm -rf custom-plans
git add -A >/dev/null && git commit -qm settle >/dev/null 2>&1

echo "== autoplan: a released cycle re-arms on the NEXT plan edit =="
mkdir -p docs/plans
PFP="$(fp_now docs/plans docs/PLANS)"
arm_plan_fp main plan-main 2 0 0 "$PFP"
echo "# plan v1" > docs/plans/p.md
expect_block "changed plan doc -> block"
# A dispatch appended — with the plan snapshot the driver writes beside it for
# the armed plan thread. Without it the fixture described growth no 0.9 driver
# could have produced, and the gate refuses to release on that: it cannot tell
# a stress-test of the current plan from one of a plan since edited.
printf 'REPLY:\n  stress-tested\n' > "$SD/plan-main.log"
printf '%s\n' "$(fp_now docs/plans docs/PLANS)" > "$SD/plan-main.dispatch-fp-plan"
expect_allow "post-arming dispatch releases"
[[ -n "$(sed -n 's/^released_fp=//p' "$SD/autoplan.armed")" ]] && ok "autoplan records released_fp" || bad "autoplan release not recorded"
expect_allow "no further plan change -> still allow"
echo "# plan v2 — new section" >> docs/plans/p.md
expect_block "NEXT plan edit needs its own dispatch (was: allow forever)"
rm -f "$SD/autoplan.armed"
rm -rf docs; git add -A >/dev/null; git commit -qm "cleanup" >/dev/null 2>&1

summary
