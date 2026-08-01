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
arm_plan_fp() { # branch thread cap blocks log_bytes fp
  mkdir -p "$SD"
  printf 'branch=%s\nthread=%s\nlens=stress-test\ncap=%s\nblocks=%s\nlog_bytes_at_arming=%s\nfp_at_arming=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" > "$SD/autoplan.armed"
}
reply_log() { printf 'REPLY:\n  %s\n' "$1" > "$SD/review-main.log"; }   # overwrite: one verdict, at offset 0

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
# The script promises to print nothing when it cannot compute. It used to
# silence every git invocation and hash whatever came out, so a failure
# produced a confident but wrong hash — the one outcome it promises never to
# produce. A dangling symlink is NOT such a case: git records the link itself,
# so it hashes fine and must keep doing so.
git checkout -q -- . 2>/dev/null; git clean -qfd 2>/dev/null
echo v1 > zzz.txt
FP_BEFORE="$(fp_now)"
ln -s /nonexistent/target aaa-dangling
[[ -n "$(fp_now)" && "$(fp_now)" != "$FP_BEFORE" ]] && ok "a dangling symlink is hashable content, not a failure" || bad "dangling symlink broke the fingerprint"
rm -f aaa-dangling
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
# It hashes CONTENT, so committing is not itself an event. Both directions
# matter and an earlier version got one of them wrong:
#   - the content still differs from the pre-edit state, so a fix survives its
#     own commit and the gate stays engaged (a bare dirty-tree test goes quiet
#     here, exactly when the follow-up round is still owed);
#   - committing the SAME bytes is not a change, so approving work and then
#     committing it costs no review round. Hashing HEAD made it cost one.
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

echo "== fingerprint: the state dir is excluded even when NOT gitignored =="
# The add cannot name the state dir in a pathspec (git exits 1 when a pathspec
# names an ignored path, which is the normal case), so it is dropped from the
# throwaway index instead — which also covers a repo that never ignored it.
mkdir -p "$SD"
# The developer's GLOBAL gitignore also covers .claude/codex-threads, so moving
# the repo .gitignore aside is not enough — without neutralising core.excludesFile
# this test passes even with the exclusion deleted. (It did; a mutation caught it.)
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
expect_allow "the approved state releases this turn"
expect_block "the code added after the verdict is still gated"
rm -f "$SD/review-main.dispatch-fp"
# A malformed snapshot must not poison the release — fall back to the hook's own.
git add -A >/dev/null && git commit -qm "settle" >/dev/null 2>&1
: > "$SD/review-main.log"
arm_review_fp main review-main 3 0 0 "$(fp_now)"
echo "x" >> f.txt; expect_block "cycle opens"
echo "not-a-fingerprint" > "$SD/review-main.dispatch-fp"
reply_log APPROVE
expect_allow "a malformed dispatch-fp falls back instead of blocking forever"
rm -f "$SD/review-main.dispatch-fp" "$SD/autoreview.armed"
git add -A >/dev/null && git commit -qm "settle" >/dev/null 2>&1

echo "== a pre-0.9 armed file adopts the cycle model at its FIRST release =="
# The compatibility promise is "keeps the old behaviour UNTIL its first
# release", not "forever". The old test only exercised clean/dirty/commit and
# never reached a release, so it could not have caught this either way.
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

echo "== BOTH gates armed: a block on one must not bank the other's verdicts =="
# emit_block and allow exit the whole hook, so a block on autoreview used to
# skip autoplan entirely — including its idle-verdict consumption. Plan-thread
# growth during the blocked turn then banked and released the next plan cycle
# free. Nothing tested the two gates together, which is why it survived.
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

echo "== autoplan: a released cycle re-arms on the NEXT plan edit =="
mkdir -p docs/plans
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
