#!/usr/bin/env bash
# Product-route checks for the exact-candidate required-review boundary.
# No hook, cleanup, migration, or optional self-gate behavior belongs here.
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/plugins/cc-codex-triage"
STATE="$PLUGIN/scripts/review-state.sh"
STATE_DIR_HELPER="$PLUGIN/scripts/state-dir.sh"
STATUS="$PLUGIN/scripts/status.sh"
VERDICT="$PLUGIN/scripts/verdict.sh"
DISPATCH="$PLUGIN/scripts/dispatch.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/cc-review-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/codex" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'codex-cli 0.149.1'; exit 0; fi
out=""; prev=""
for arg in "$@"; do
  [ "$prev" = -o ] && out="$arg"
  prev="$arg"
done
cat >/dev/null
printf '{"type":"thread.started","thread_id":"0a1b2c3d-1111-4222-8333-444455556666"}\n'
printf 'reviewed the exact candidate\nAPPROVE' > "$out"
STUB
chmod +x "$T/bin/codex"
export PATH="$T/bin:$PATH"
REPO="$T/repo"
mkdir -p "$REPO/docs"
cd "$REPO"
git init -q -b main .
git config user.name test
git config user.email test@example.com
printf 'spec\n' > docs/spec.md
printf 'candidate\n' > app.txt
git add docs/spec.md app.txt
git commit -qm baseline
SD="$REPO/.git/cc-codex-triage/threads"

field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

begin() { # thread cap
  BOUT="$("$STATE" begin "$1" --base HEAD --spec docs/spec.md --cap "${2:-3}" 2>"$T/err")"
  BRC=$?
  CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
}

append_reply() { # thread verdict [spec] [head]
  local thread="$1" verdict="$2" spec="${3:-docs/spec.md}" head="${4:-$(git rev-parse HEAD)}"
  local base round
  base="$(field "$SD/$thread.candidate" base_sha)"
  round="$(cat "$SD/$thread.rounds" 2>/dev/null || printf '0')"
  case "$round" in ''|*[!0-9]*) round=0 ;; esac
  printf '[test] mode=resume thread=%s round=%s\nPROMPT:\n  REQUIRED_REVIEW\n  BASE_SHA: %s\n  CANDIDATE_SHA: %s\n  SPEC_PATH: %s\nREPLY:\n  %s\n---\n' \
    "$thread" "$((round + 1))" "$base" "$head" "$spec" "$verdict" >> "$SD/$thread.log"
  printf '%s\n' "$((round + 1))" > "$SD/$thread.rounds"
}

approve() { # thread
  begin "$1" 3
  append_reply "$1" APPROVE
  AOUT="$("$STATE" record "$1" "$CLAIM" 2>"$T/err")"
  ARC=$?
}

echo "== one strict parser at the delivery boundary =="
cat > "$T/strict.log" <<'EOF'
[test]
PROMPT:
  APPROVE
REPLY:
  body
  APPROVE
---
EOF
VOUT="$("$VERDICT" "$T/strict.log")"; VRC=$?
[[ "$VRC" -eq 0 && "$VOUT" == APPROVE ]] \
  && ok "strict accepts one final bare verdict from REPLY" \
  || bad "strict verdict rc=$VRC out=$VOUT"

sed 's/^  APPROVE$/  **APPROVE**/' "$T/strict.log" > "$T/decorated.log"
"$VERDICT" "$T/decorated.log" >/dev/null 2>&1 \
  && bad "strict accepted Markdown decoration" \
  || ok "strict rejects decorated verdicts"

awk '/^---$/{print "REPLY:\n  REQUEST_CHANGES\n---"} {print}' "$T/strict.log" > "$T/duplicate.log"
"$VERDICT" "$T/duplicate.log" >/dev/null 2>&1 \
  && bad "strict accepted two verdicts" \
  || ok "strict rejects ambiguous duplicate verdicts"
"$VERDICT" informational "$T/strict.log" >/dev/null 2>&1 \
  && bad "removed display-only verdict policy is still callable" \
  || ok "the parser exposes no tolerant display policy"

echo "== complete required-review product route =="
begin product-route 3
ROUTE_BASE="$(field "$SD/product-route.candidate" base_sha)"
ROUTE_HEAD="$(field "$SD/product-route.candidate" head)"
ROUTE_PROMPT="REQUIRED_REVIEW
BASE_SHA: $ROUTE_BASE
CANDIDATE_SHA: $ROUTE_HEAD
SPEC_PATH: docs/spec.md
Review the candidate. End with one bare verdict."
ROUTE_OUT="$(CC_DISPATCH_WAIT=10 "$DISPATCH" product-route <<< "$ROUTE_PROMPT" 2>"$T/err")"; ROUTE_RC=$?
[[ "$ROUTE_RC" -eq 0 && "$ROUTE_OUT" == *APPROVE ]] \
  && ok "dispatch writes the claimed round through the production driver" \
  || bad "product dispatch rc=$ROUTE_RC out=$ROUTE_OUT err=$(cat "$T/err")"
ROUTE_RECORD="$("$STATE" record product-route "$CLAIM" 2>"$T/err")"; ROUTE_RECORD_RC=$?
[[ "$ROUTE_RECORD_RC" -eq 0 && "$ROUTE_RECORD" == APPROVE\ head=* ]] \
  && ok "record attributes the production log to the claim" \
  || bad "product record rc=$ROUTE_RECORD_RC out=$ROUTE_RECORD err=$(cat "$T/err")"
ROUTE_CHECK="$("$STATE" check product-route 2>"$T/err")"; ROUTE_CHECK_RC=$?
[[ "$ROUTE_CHECK_RC" -eq 0 && "$ROUTE_CHECK" == CC_CODEX_REQUIRED_REVIEW\ APPROVE\ thread=product-route* ]] \
  && ok "check authorizes the exact candidate end to end" \
  || bad "product check rc=$ROUTE_CHECK_RC out=$ROUTE_CHECK err=$(cat "$T/err")"

begin one-record-route 3
append_reply one-record-route APPROVE
"$STATE" record one-record-route background "$CLAIM" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -ne 0 ]] \
  && ok "record has no parallel background/observed mode" \
  || bad "legacy record mode still accepted a verdict"
"$STATE" reset one-record-route >/dev/null 2>&1

echo "== exact clean candidate approval =="
approve exact
[[ "$BRC" -eq 0 && -n "$CLAIM" ]] \
  && ok "begin publishes a claim for a clean candidate" \
  || bad "begin rc=$BRC out=$BOUT err=$(cat "$T/err")"
[[ "$ARC" -eq 0 && "$AOUT" == APPROVE\ head=* ]] \
  && ok "the claimed APPROVE is recorded" \
  || bad "record rc=$ARC out=$AOUT err=$(cat "$T/err")"
COUT="$("$STATE" check exact 2>"$T/err")"; CRC=$?
[[ "$CRC" -eq 0 && "$COUT" == CC_CODEX_REQUIRED_REVIEW\ APPROVE\ thread=exact* ]] \
  && ok "check authorizes exactly the approved candidate" \
  || bad "check rc=$CRC out=$COUT err=$(cat "$T/err")"
SOUT="$("$STATUS")"; SRC=$?
[[ "$SRC" -eq 0 && "$SOUT" == *"exact"*"status=APPROVED"* ]] \
  && ok "status displays the recorded approval without re-deciding it" \
  || bad "status omitted approval: $SOUT"
printf '%s\n' "$SOUT" | awk '
  /^Threads:/{threads=1; next}
  /^Required review:/{threads=0}
  threads && /verdict=/{found=1}
  END{exit found}
' \
  && ok "ordinary thread rows do not infer an approval-like verdict from log prose" \
  || bad "status still decorates ordinary threads with an inferred verdict: $SOUT"

echo "== fail closed on candidate and prompt drift =="
begin dirty 3
append_reply dirty APPROVE
printf 'dirty\n' >> app.txt
"$STATE" record dirty "$CLAIM" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 11 && "$(field "$SD/dirty.review-state" reason)" == dirty_worktree ]] \
  && ok "a dirty worktree cannot inherit approval" \
  || bad "dirty candidate rc=$RC reason=$(field "$SD/dirty.review-state" reason)"
git restore app.txt

begin moved 3
OLD_HEAD="$(git rev-parse HEAD)"
append_reply moved APPROVE docs/spec.md "$OLD_HEAD"
printf 'next\n' >> app.txt
git add app.txt && git commit -qm next
"$STATE" record moved "$CLAIM" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 11 && "$(field "$SD/moved.review-state" reason)" == head_moved ]] \
  && ok "a moved HEAD makes the verdict stale" \
  || bad "moved candidate rc=$RC reason=$(field "$SD/moved.review-state" reason)"

begin scope 3
append_reply scope APPROVE docs/other.md
"$STATE" record scope "$CLAIM" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 11 && "$(field "$SD/scope.review-state" reason)" == prompt_scope_mismatch ]] \
  && ok "mismatched scope markers cannot authorize delivery" \
  || bad "scope mismatch rc=$RC reason=$(field "$SD/scope.review-state" reason)"

echo "== review loop outcomes =="
begin refute 3
append_reply refute REQUEST_CHANGES
"$STATE" record refute "$CLAIM" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 10 && "$(field "$SD/refute.review-state" status)" == REQUEST_CHANGES ]] \
  && ok "REQUEST_CHANGES blocks delivery" \
  || bad "request changes rc=$RC status=$(field "$SD/refute.review-state" status)"
begin refute 3
append_reply refute APPROVE
"$STATE" record refute "$CLAIM" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 0 ]] \
  && ok "a refuted finding can be reconsidered on the same clean candidate" \
  || bad "same-candidate retry rc=$RC err=$(cat "$T/err")"

begin capped 1
append_reply capped REQUEST_CHANGES
"$STATE" record capped "$CLAIM" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 10 && "$(field "$SD/capped.review-state" status)" == CAP_REACHED ]] \
  && ok "the configured cap is a hard stop" \
  || bad "cap rc=$RC status=$(field "$SD/capped.review-state" status)"
"$STATE" begin capped --base HEAD --spec docs/spec.md --cap 1 >/dev/null 2>&1 \
  && bad "a capped thread restarted without reset" \
  || ok "a capped thread requires an explicit reset"
"$STATE" reset capped >/dev/null 2>"$T/err" \
  && ok "reset clears the hard stop" \
  || bad "reset failed: $(cat "$T/err")"

echo "== concurrent claim and read-only status =="
rm -f "$SD/race."*
("$STATE" begin race --base HEAD --spec docs/spec.md --cap 3 >"$T/race-a" 2>&1; echo $? >"$T/race-a.rc") &
PA=$!
("$STATE" begin race --base HEAD --spec docs/spec.md --cap 3 >"$T/race-b" 2>&1; echo $? >"$T/race-b.rc") &
PB=$!
wait "$PA"; wait "$PB"
RA="$(cat "$T/race-a.rc")"; RB="$(cat "$T/race-b.rc")"
[[ "$RA:$RB" == 0:10 || "$RA:$RB" == 10:0 ]] \
  && ok "only one concurrent begin owns the review round" \
  || bad "concurrent begin statuses were $RA and $RB"
SOUT="$("$STATUS")"
[[ "$SOUT" == *"race"*"status=PENDING"* ]] \
  && ok "status makes an in-flight required round visible" \
  || bad "status omitted pending round: $SOUT"

rm -rf "$SD"
SOUT="$("$STATUS" 2>"$T/err")"; SRC=$?
[[ "$SRC" -eq 0 && ! -e "$SD" ]] \
  && ok "status is read-only and does not create state" \
  || bad "status rc=$SRC created state: $(cat "$T/err")"

echo "== linked worktrees never share a saved Codex session =="
git branch linked >/dev/null
WT="$T/linked"
git worktree add -q "$WT" linked
MAIN_STATE="$(cd "$REPO" && "$STATE_DIR_HELPER")"
LINK_STATE="$(cd "$WT" && "$STATE_DIR_HELPER")"
[[ "$MAIN_STATE" != "$LINK_STATE" ]] \
  && ok "each worktree resolves a different state directory" \
  || bad "worktrees shared state: $MAIN_STATE"
OVERRIDDEN_STATE="$(cd "$WT" && CC_CODEX_STATE_DIR="$MAIN_STATE" "$STATE_DIR_HELPER")"
[[ "$OVERRIDDEN_STATE" == "$LINK_STATE" ]] \
  && ok "an environment override cannot reconnect two worktrees" \
  || bad "CC_CODEX_STATE_DIR bypassed worktree isolation: $OVERRIDDEN_STATE"
printf 'session\n' > "$MAIN_STATE/review-main.id"
[[ ! -e "$LINK_STATE/review-main.id" ]] \
  && ok "a saved session id is not visible from another worktree" \
  || bad "linked worktree can resume the main worktree session"

summary
