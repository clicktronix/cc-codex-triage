#!/usr/bin/env bash
# Regression suite for hooks/stop-hook.sh. No Codex needed — synthetic state.
# Usage: bash tests/hook-regression.sh   (exit 0 = all pass)
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/plugins/cc-codex-triage/hooks/stop-hook.sh"
[[ -f "$HOOK" ]] || { echo "hook not found: $HOOK"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cc-hook-test.XXXXXX")"
ERR="$(mktemp "${TMPDIR:-/tmp}/cc-hook-err.XXXXXX")"   # OUTSIDE the test repo — an err file inside would dirty the tree
trap 'rm -rf "$T" "$ERR"' EXIT
cd "$T"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

run_hook() { printf '%s' "${1:-{\"hook_event_name\":\"Stop\"}}" | bash "$HOOK" 2>"$ERR"; }

expect_allow() { local out; out="$(run_hook "${2:-}")"; [[ -z "$out" ]] && ok "$1" || { bad "$1 (got: $out)"; }; }
expect_block() { local out; out="$(run_hook "${2:-}")"; [[ "$out" == '{"decision":"block"'* ]] && ok "$1" || bad "$1 (got: ${out:-empty})"; }
expect_valid_json() { local out; out="$(run_hook "${2:-}")"; if command -v jq >/dev/null; then printf '%s' "$out" | jq empty 2>/dev/null && ok "$1" || bad "$1 (invalid json: $out)"; else ok "$1 (jq absent, skipped strict check)"; fi; }

SD=.claude/codex-threads
arm_review() { mkdir -p "$SD"; printf 'branch=%s\nthread=%s\nlens=correctness\ncap=%s\nblocks=%s\n' "$1" "$2" "$3" "$4" > "$SD/autoreview.armed"; }

echo "== no git repo =="
expect_allow "no repo at all"

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

echo "== quote-in-branch cannot break JSON =="
arm_review main 'review-x' 3 0
sed -i.bak 's/^lens=.*/lens=correct"ness\\evil/' "$SD/autoreview.armed" && rm -f "$SD/autoreview.armed.bak"
expect_valid_json "reason sanitized to valid JSON"

echo "== invalid thread name falls back to slugified branch =="
git checkout -qb 'feat/slash' 2>/dev/null
arm_review 'feat/slash' 'bad thread name!!' 3 0
out="$(run_hook)"
printf '%s' "$out" | grep -q -- '--thread review-feat-slash' && ok "fallback thread slugified" || bad "fallback not slugified (got: $out)"
git checkout -q main

echo "== APPROVE in log releases =="
arm_review main review-main 3 0
printf 'PROMPT:\n  - Last line is the verdict: APPROVE | REQUEST_CHANGES | COMMENT\nREPLY:\n  stuff\n  APPROVE---\n---\n' > "$SD/review-main.log"
expect_allow "APPROVE gate releases"

echo "== contract line in PROMPT does not fake a verdict =="
printf 'PROMPT:\n  - Last line is the verdict: APPROVE | REQUEST_CHANGES | COMMENT\nREPLY:\n  no verdict yet\n---\n' > "$SD/review-main.log"
expect_block "no standalone verdict -> still blocks"

echo "== Verdict: APPROVE prefixed form also releases =="
printf 'REPLY:\n  Verdict: APPROVE\n---\n' > "$SD/review-main.log"
expect_allow "prefixed verdict releases"

echo "== wrong branch allows =="
arm_review other-branch review-other 3 0
expect_allow "branch mismatch allows"
rm -f "$SD/autoreview.armed" "$SD/review-main.log"
git checkout -q f.txt

echo "== autoplan: block, then release on round-count CHANGE (incl. thread-new reset) =="
mkdir -p docs/plans && echo p > docs/plans/x.md
echo "5" > "$SD/plan-main.rounds"   # realistic arming: snapshot equals the live counter
printf 'branch=main\nthread=plan-main\nlens=stress-test\ncap=2\nblocks=0\nrounds_at_arming=5\n' > "$SD/autoplan.armed"
expect_block "autoplan blocks on plan dirt"
echo "1" > "$SD/plan-main.rounds"   # thread-new reset + one fresh /plan run -> 1 != 5
expect_allow "autoplan releases on rounds!=armed (post thread-new)"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
