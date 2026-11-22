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
[ -z "${FAKE_CODEX_CALLS:-}" ] || echo called >> "$FAKE_CODEX_CALLS"
printf '{"type":"thread.started","thread_id":"0a1b2c3d-1111-4222-8333-444455556666"}\n'
printf '%s\n%s\n' "${FAKE_REVIEW_BODY:-reviewed the exact candidate; see app.txt:1}" "${FAKE_REVIEW_VERDICT:-APPROVE}" > "$out"
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

append_reply() { # exercise the driver; wrong scope stays a recorder refusal
  local thread="$1" verdict="$2" spec="${3:-docs/spec.md}" head="${4:-$(git rev-parse HEAD)}" base
  base="$(field "$SD/$thread.candidate" base_sha)"
  FAKE_REVIEW_VERDICT="$verdict" "$PLUGIN/scripts/codex-thread.sh" "$thread" --strict <<EOF >/dev/null
REQUIRED_REVIEW
BASE_SHA: $base
CANDIDATE_SHA: $head
SPEC_PATH: $spec
Review the candidate.
EOF
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

echo "== the header is generated and checked before the paid call =="
begin preflight-route 3
PF_BASE="$(field "$SD/preflight-route.candidate" base_sha)"
PF_HEAD="$(field "$SD/preflight-route.candidate" head)"
HDR="$("$STATE" header preflight-route 2>"$T/err")"
[[ "$HDR" == "REQUIRED_REVIEW"$'\n'"BASE_SHA: $PF_BASE"$'\n'"CANDIDATE_SHA: $PF_HEAD"$'\n'"SPEC_PATH: docs/spec.md" ]] \
  && ok "header prints the claimed base, candidate and spec" \
  || bad "header output: $HDR err=$(cat "$T/err")"
: > "$T/calls"
SHORT_PROMPT="REQUIRED_REVIEW
BASE_SHA: $PF_BASE
CANDIDATE_SHA: ${PF_HEAD:0:12}
SPEC_PATH: docs/spec.md
Review the candidate."
FAKE_CODEX_CALLS="$T/calls" CC_DISPATCH_WAIT=10 "$DISPATCH" preflight-route <<< "$SHORT_PROMPT" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 14 && ! -s "$T/calls" ]] \
  && ok "a short candidate SHA is refused before Codex is called" \
  || bad "short SHA rc=$RC calls=$(wc -l < "$T/calls") err=$(cat "$T/err")"
grep -q "nothing was dispatched" "$T/err" \
  && ok "the refusal says nothing was paid for" \
  || bad "refusal text: $(cat "$T/err")"
DUP_PROMPT="$HDR
Review the candidate.
CANDIDATE_SHA: $PF_HEAD"
FAKE_CODEX_CALLS="$T/calls" CC_DISPATCH_WAIT=10 "$DISPATCH" preflight-route <<< "$DUP_PROMPT" >/dev/null 2>&1; RC=$?
[[ "$RC" -eq 14 && ! -s "$T/calls" ]] \
  && ok "a header line repeated in the body is refused before dispatch" \
  || bad "duplicate header rc=$RC"
PF_OUT="$(FAKE_CODEX_CALLS="$T/calls" CC_DISPATCH_WAIT=10 "$DISPATCH" preflight-route <<< "$HDR
Review the candidate." 2>"$T/err")"; RC=$?
[[ "$RC" -eq 0 && -s "$T/calls" && "$PF_OUT" == *APPROVE ]] \
  && ok "the generated header dispatches and the round records" \
  || bad "generated header rc=$RC out=$PF_OUT err=$(cat "$T/err")"
"$STATE" record preflight-route "$CLAIM" >/dev/null 2>&1 \
  && ok "the round dispatched with the generated header is recordable" \
  || bad "generated-header round did not record"
"$STATE" reset preflight-route >/dev/null 2>&1

echo "== a blocking verdict without findings is not counted =="
begin empty-findings 2
FAKE_REVIEW_BODY="looks wrong somehow" append_reply empty-findings REQUEST_CHANGES
EOUT="$("$STATE" record empty-findings "$CLAIM" 2>&1)"; ERC=$?
[[ "$ERC" -eq 10 && "$EOUT" == *NO_FINDINGS* && "$(field "$SD/empty-findings.review-loop" attempts)" == 0 ]] \
  && ok "REQUEST_CHANGES with no file:line finding returns its attempt" \
  || bad "empty findings rc=$ERC out=$EOUT attempts=$(field "$SD/empty-findings.review-loop" attempts)"
begin empty-findings 2
[[ "$BRC" -eq 0 && "$BOUT" == *"attempt=1/2"* ]] \
  && ok "the next round starts at the same attempt" \
  || bad "after empty findings: rc=$BRC out=$BOUT"
append_reply empty-findings REQUEST_CHANGES
"$STATE" record empty-findings "$CLAIM" >/dev/null 2>&1
[[ "$(field "$SD/empty-findings.review-state" status)" == REQUEST_CHANGES && "$(field "$SD/empty-findings.review-loop" attempts)" == 1 ]] \
  && ok "a blocking verdict with a located finding still counts" \
  || bad "located finding status: $(field "$SD/empty-findings.review-state" status)"
"$STATE" reset empty-findings >/dev/null 2>&1

echo "== an integration round after an approval does not spend the cap =="
git checkout -q -b integ-target
printf 'target moved\n' > target.txt; git add target.txt; git commit -qm "target advances"
git checkout -q main
begin integ 2
append_reply integ APPROVE
"$STATE" record integ "$CLAIM" >/dev/null 2>&1
APPROVED_HEAD="$(git rev-parse HEAD)"
[[ "$(field "$SD/integ.review-loop" attempts)" == 1 ]] && ok "the approval used one attempt" || bad "attempts after approval: $(field "$SD/integ.review-loop" attempts)"
BASE_FOR_INTEG="$(field "$SD/integ.candidate" base_sha)"
BOUT="$("$STATE" begin integ --base "$BASE_FOR_INTEG" --spec docs/spec.md --cap 2 --integration 2>&1)"; BRC=$?
[[ "$BRC" -ne 0 && "$BOUT" == *INTEGRATION_REFUSED* ]] \
  && ok "an integration round needs a merge of the approved candidate" \
  || bad "non-merge integration rc=$BRC out=$BOUT"
git merge -q --no-ff --no-edit integ-target
BOUT="$("$STATE" begin integ --base "$BASE_FOR_INTEG" --spec docs/spec.md --cap 2 --integration 2>&1)"; BRC=$?
CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
[[ "$BRC" -eq 0 && "$BOUT" == *"attempt=1/2"* && "$BOUT" == *"integration_of=$APPROVED_HEAD"* ]] \
  && ok "the integration round keeps the attempt count" \
  || bad "integration begin rc=$BRC out=$BOUT"
append_reply integ APPROVE
IOUT="$("$STATE" record integ "$CLAIM" 2>&1)"; IRC=$?
[[ "$IRC" -eq 0 && "$IOUT" == "APPROVE head=$(git rev-parse HEAD)"* && "$(field "$SD/integ.review-loop" attempts)" == 1 ]] \
  && ok "the integrated candidate is approved without spending an attempt" \
  || bad "integration record rc=$IRC out=$IOUT attempts=$(field "$SD/integ.review-loop" attempts)"
"$STATE" reset integ >/dev/null 2>&1
BOUT="$("$STATE" begin integ --base HEAD --spec docs/spec.md --cap 2 --integration 2>&1)"; BRC=$?
[[ "$BRC" -ne 0 && "$BOUT" == *INTEGRATION_REFUSED* ]] \
  && ok "an integration round without a prior approval is refused" \
  || bad "no-approval integration rc=$BRC out=$BOUT"
git reset -q --hard "$APPROVED_HEAD"

echo "== an authorized budget renews the same thread =="
begin renew-route 1
append_reply renew-route REQUEST_CHANGES
"$STATE" record renew-route "$CLAIM" >/dev/null 2>&1
[[ "$(field "$SD/renew-route.review-state" status)" == CAP_REACHED ]] && ok "one attempt reaches the cap" || bad "renew setup status: $(field "$SD/renew-route.review-state" status)"
"$STATE" renew renew-route >/dev/null 2>&1 && bad "renew without --by accepted" || ok "renew names who authorized it"
ROUT="$("$STATE" renew renew-route --by owner 2>&1)"; RRC=$?
[[ "$RRC" -eq 0 && "$ROUT" == RENEWED* && "$(field "$SD/renew-route.review-loop" renewals)" == 1 ]] \
  && ok "renew records the new budget" || bad "renew rc=$RRC out=$ROUT"
begin renew-route 1
[[ "$BRC" -eq 0 && "$BOUT" == *"attempt=1/1"* && "$(field "$SD/renew-route.review-loop" renewals)" == 1 && "$(field "$SD/renew-route.review-loop" renewed_by)" == owner ]] \
  && ok "the renewed thread claims again and keeps the renewal record" || bad "after renew rc=$BRC out=$BOUT"
"$STATE" renew renew-route --by owner >/dev/null 2>&1 && bad "renew accepted outside CAP_REACHED" || ok "renew is refused while a round is pending"
"$STATE" abort renew-route dispatch-failure "$CLAIM" >/dev/null 2>&1
"$STATE" reset renew-route >/dev/null 2>&1

echo "== consecutive authorized renewals each start a new set of rounds =="
begin renew-twice 1
append_reply renew-twice REQUEST_CHANGES
"$STATE" record renew-twice "$CLAIM" >/dev/null 2>&1
"$STATE" renew renew-twice --by owner >/dev/null 2>&1
begin renew-twice 1
append_reply renew-twice REQUEST_CHANGES
"$STATE" record renew-twice "$CLAIM" >/dev/null 2>&1
[[ "$BRC" -eq 0 && "$(field "$SD/renew-twice.review-state" status)" == CAP_REACHED ]] \
  && ok "the first renewal's round reaches the cap again" || bad "first renewed round rc=$BRC status=$(field "$SD/renew-twice.review-state" status)"
ROUT="$("$STATE" renew renew-twice --by owner 2>&1)"; RRC=$?
[[ "$RRC" -eq 0 && "$ROUT" == RENEWED* && "$(field "$SD/renew-twice.review-loop" renewals)" == 2 ]] \
  && ok "the same owner's second renewal is recorded" || bad "second renew rc=$RRC out=$ROUT renewals=$(field "$SD/renew-twice.review-loop" renewals)"
begin renew-twice 1
[[ "$BRC" -eq 0 && "$BOUT" == *"attempt=1/1"* ]] \
  && ok "the round after the second renewal is claimed" || bad "after second renew rc=$BRC out=$BOUT err=$(cat "$T/err")"
"$STATE" abort renew-twice dispatch-failure "$CLAIM" >/dev/null 2>&1
"$STATE" reset renew-twice >/dev/null 2>&1

echo "== a renewal without a round in between is refused =="
begin renew-idle 1
append_reply renew-idle REQUEST_CHANGES
"$STATE" record renew-idle "$CLAIM" >/dev/null 2>&1
"$STATE" renew renew-idle --by owner >/dev/null 2>&1
ROUT="$("$STATE" renew renew-idle --by owner 2>&1)"; RRC=$?
[[ "$RRC" -eq 10 && "$ROUT" == *RENEW_REFUSED* && "$(field "$SD/renew-idle.review-loop" renewals)" == 1 ]] \
  && ok "a repeated renew grants nothing and says so" || bad "idle second renew rc=$RRC out=$ROUT renewals=$(field "$SD/renew-idle.review-loop" renewals)"
"$STATE" reset renew-idle >/dev/null 2>&1

echo "== renew takes only --by, and the usage line keeps the verbs callers match =="
begin renew-flags 1
append_reply renew-flags REQUEST_CHANGES
"$STATE" record renew-flags "$CLAIM" >/dev/null 2>&1
for flag in "--rounds 3" "--grant x"; do
  # shellcheck disable=SC2086 # the flag and its value are two words
  "$STATE" renew renew-flags --by owner $flag >/dev/null 2>&1; RC=$?
  [[ "$RC" -eq 1 && "$(field "$SD/renew-flags.review-state" status)" == CAP_REACHED ]] \
    && ok "renew $flag is a usage error" || bad "renew $flag rc=$RC"
done
"$STATE" reset renew-flags >/dev/null 2>&1
USAGE="$("$STATE" 2>&1)"
[[ "$USAGE" == *--integration* && "$USAGE" == *"check <thread>"* && "$USAGE" == *"renew <thread> --by"* \
   && "$USAGE" != *--rounds* && "$USAGE" != *--grant* ]] \
  && ok "usage names --integration, check and renew --by, and no removed flag" || bad "usage: $USAGE"

echo "== the loop file stays version 1 through every transition =="
V1_FIELDS="version base_sha spec_path cap start_round attempts renewals renewed_by timestamp "
V1_BAD=""
loop_v1() { # label
  [[ "$(field "$SD/v1-loop.review-loop" version)" == 1 \
     && "$(sed -n 's/=.*//p' "$SD/v1-loop.review-loop" | tr '\n' ' ')" == "$V1_FIELDS" ]] || V1_BAD="$V1_BAD $1"
}
begin v1-loop 2; loop_v1 begin
"$STATE" abort v1-loop dispatch-failure "$CLAIM" >/dev/null 2>&1; loop_v1 abort
begin v1-loop 2
FAKE_REVIEW_BODY="no location here" append_reply v1-loop REQUEST_CHANGES
"$STATE" record v1-loop "$CLAIM" >/dev/null 2>&1; loop_v1 no-findings
begin v1-loop 2
append_reply v1-loop REQUEST_CHANGES
"$STATE" record v1-loop "$CLAIM" >/dev/null 2>&1; loop_v1 request-changes
begin v1-loop 2
append_reply v1-loop COMMENT
"$STATE" record v1-loop "$CLAIM" >/dev/null 2>&1; loop_v1 cap-reached
"$STATE" renew v1-loop --by owner >/dev/null 2>&1; loop_v1 renew
begin v1-loop 2
append_reply v1-loop APPROVE
"$STATE" record v1-loop "$CLAIM" >/dev/null 2>&1; loop_v1 approve
[[ -z "$V1_BAD" && "$(field "$SD/v1-loop.review-state" status)" == APPROVED ]] \
  && ok "begin, abort, record of each verdict and renew write the v1 loop field set" \
  || bad "non-v1 loop after:$V1_BAD; status=$(field "$SD/v1-loop.review-state" status)"
"$STATE" reset v1-loop >/dev/null 2>&1

echo "== a finding in a file without an extension is a finding =="
begin extless 2
FAKE_REVIEW_BODY="Dockerfile:3 copies a missing artifact and the build fails" append_reply extless REQUEST_CHANGES
"$STATE" record extless "$CLAIM" >/dev/null 2>&1
[[ "$(field "$SD/extless.review-state" status)" == REQUEST_CHANGES && "$(field "$SD/extless.review-loop" attempts)" == 1 ]] \
  && ok "Dockerfile:3 counts as a located finding" || bad "extensionless status: $(field "$SD/extless.review-state" status)"
"$STATE" reset extless >/dev/null 2>&1

echo "== Unicode findings; a plain spec path gives a seven-field marker =="
printf 'spec\n' > 'docs/План работ.md'
printf 'entry\n' > Словарь
printf 'spec\n' > ' lead.md'
printf 'spec\n' > 'docs/trail.md '
git add -- 'docs/План работ.md' Словарь ' lead.md' 'docs/trail.md ' && git commit -qm 'Add Unicode fixture'
for verdict in REQUEST_CHANGES APPROVE; do
  BOUT="$("$STATE" begin unicode --base HEAD --spec docs/spec.md)"
  CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
  HDR="$("$STATE" header unicode)"
  FAKE_REVIEW_BODY="Словарь:1 correct the entry" FAKE_REVIEW_VERDICT="$verdict" "$DISPATCH" unicode --strict <<< "$HDR" >/dev/null
  "$STATE" record unicode "$CLAIM" >/dev/null 2>&1
  status="$(field "$SD/unicode.review-state" status)"
  if [ "$verdict" = REQUEST_CHANGES ]; then
    [[ "$status" = REQUEST_CHANGES ]] && ok "Unicode file:line remains actionable" || bad "Unicode finding: $status"
  fi
done
marker="$("$STATE" check unicode)"
expected="CC_CODEX_REQUIRED_REVIEW APPROVE thread=unicode head=$(git rev-parse HEAD) tree=$(git rev-parse 'HEAD^{tree}') base_sha=$(git rev-parse HEAD) spec_path=docs/spec.md"
read -ra marker_fields <<< "$marker"
[[ "$marker" = "$expected" && "${#marker_fields[@]}" -eq 7 ]] \
  && ok "the approval marker splits into exactly seven fields" || bad "marker: $marker (${#marker_fields[@]} fields)"

echo "== a spec path with spaces ends the marker as spec_path=<rest of line> =="
SPACED='docs/План работ.md'
BOUT="$("$STATE" begin spaced --base HEAD --spec "$SPACED" 2>"$T/err")"; RC=$?
CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
"$STATE" header spaced 2>/dev/null | FAKE_REVIEW_VERDICT=APPROVE "$DISPATCH" spaced --strict >/dev/null 2>&1
"$STATE" record spaced "$CLAIM" >/dev/null 2>&1
marker="$("$STATE" check spaced 2>/dev/null)"
prefix="CC_CODEX_REQUIRED_REVIEW APPROVE thread=spaced head=$(git rev-parse HEAD) tree=$(git rev-parse 'HEAD^{tree}') base_sha=$(git rev-parse HEAD)"
read -ra prefix_fields <<< "${marker%% spec_path=*}"
[[ "$RC" -eq 0 && "$marker" = "$prefix spec_path=$SPACED" && "${#prefix_fields[@]}" -eq 6 ]] \
  && ok "six fields, then the spaced Unicode path to the end of the line" \
  || bad "spaced spec rc=$RC marker=$marker err=$(cat "$T/err")"
for edge in ' lead.md' 'docs/trail.md '; do
  "$STATE" begin edge --base HEAD --spec "$edge" 2>"$T/err"; RC=$?
  [[ "$RC" -eq 1 ]] && grep -q 'start or end with a space' "$T/err" \
    && ok "tracked spec '$edge' is refused: the marker's last field has no outer spaces" \
    || bad "outer-space spec '$edge' rc=$RC err=$(cat "$T/err")"
done
"$STATE" begin newline --base HEAD --spec $'line\nbreak' 2>"$T/err" && bad "multiline spec accepted"
grep -q 'one line' "$T/err" && ok "multiline spec rejected at begin" || bad "multiline spec diagnostic"

echo "== a live claim is checked even when the prompt drops its first line =="
begin nomarker 2
NM_HDR="$("$STATE" header nomarker)"
: > "$T/calls"
FAKE_CODEX_CALLS="$T/calls" CC_DISPATCH_WAIT=10 "$DISPATCH" nomarker <<< "$(printf '%s\n' "$NM_HDR" | tail -n +2)
Review the candidate." >/dev/null 2>&1; RC=$?
[[ "$RC" -eq 14 && ! -s "$T/calls" ]] \
  && ok "a prompt without REQUIRED_REVIEW is refused before Codex while a claim is live" || bad "missing marker rc=$RC calls=$(wc -l < "$T/calls")"
"$STATE" abort nomarker dispatch-failure "$CLAIM" >/dev/null 2>&1
"$STATE" reset nomarker >/dev/null 2>&1

echo "== a technically failed integration round can be retried outside the cap =="
RETRY_BASE_HEAD="$(git rev-parse HEAD)"
git checkout -q -b retry-target
printf 'retry target\n' > retry.txt; git add retry.txt; git commit -qm "retry target advances"
git checkout -q "$RETRY_BASE_HEAD" 2>/dev/null; git checkout -q -B retry-cand
begin retry-integ 1
append_reply retry-integ APPROVE
"$STATE" record retry-integ "$CLAIM" >/dev/null 2>&1
RB="$(field "$SD/retry-integ.candidate" base_sha)"
git merge -q --no-ff --no-edit retry-target
APPROVED_AT_CAP="$(git rev-parse HEAD^1)"
BOUT="$("$STATE" begin retry-integ --base "$RB" --spec docs/spec.md --cap 1 --integration 2>&1)"; BRC=$?
CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
[[ "$BRC" -eq 0 && "$BOUT" == *"attempt=1/1 integration_of=$APPROVED_AT_CAP"* ]] \
  && ok "an integration round after an approval at the cap claims without a renewal" || bad "integration at the cap rc=$BRC out=$BOUT"
"$STATE" abort retry-integ dispatch-failure "$CLAIM" >/dev/null 2>&1
BOUT="$("$STATE" begin retry-integ --base "$RB" --spec docs/spec.md --cap 1 --integration 2>&1)"; BRC=$?
CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
[[ "$BRC" -eq 0 && "$BOUT" == *"attempt=1/1"* ]] \
  && ok "an aborted integration claim is retried at the same attempt" || bad "retry after abort rc=$BRC out=$BOUT"
FAKE_REVIEW_BODY="no location here" append_reply retry-integ REQUEST_CHANGES
"$STATE" record retry-integ "$CLAIM" >/dev/null 2>&1
BOUT="$("$STATE" begin retry-integ --base "$RB" --spec docs/spec.md --cap 1 --integration 2>&1)"; BRC=$?
CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
[[ "$BRC" -eq 0 ]] && ok "an integration round after NO_FINDINGS is retried too" || bad "retry after no findings rc=$BRC out=$BOUT"
append_reply retry-integ REQUEST_CHANGES
"$STATE" record retry-integ "$CLAIM" >/dev/null 2>&1
BOUT="$("$STATE" begin retry-integ --base "$RB" --spec docs/spec.md --cap 1 --integration 2>&1)"; BRC=$?
[[ "$BRC" -ne 0 && ( "$BOUT" == *INTEGRATION_REFUSED* || "$BOUT" == *CAP_REACHED* ) && "$BOUT" != *attempt=* ]] \
  && ok "a real REQUEST_CHANGES at the cap ends the loop instead of reopening the exception" || bad "after real RC rc=$BRC out=$BOUT"
"$STATE" renew retry-integ --by owner >/dev/null 2>&1 || bad "renew review after blocking findings"
BOUT="$("$STATE" begin retry-integ --base "$RB" --spec docs/spec.md --integration 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *INTEGRATION_REFUSED* ]] \
  && ok "renewal after findings requires a normal round" || bad "integration after blocking findings: $BOUT"
BOUT="$("$STATE" begin retry-integ --base "$RB" --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 0 && "$BOUT" == *attempt=1/1* ]] \
  && ok "the authorized normal round remains available" || bad "normal round after renewal: $BOUT"
"$STATE" reset retry-integ >/dev/null 2>&1
# With rounds left, a real REQUEST_CHANGES in an integration round is refused as an integration.
git reset -q --hard HEAD^1
begin retry-integ2 2
append_reply retry-integ2 APPROVE
"$STATE" record retry-integ2 "$CLAIM" >/dev/null 2>&1
RB2="$(field "$SD/retry-integ2.candidate" base_sha)"
git merge -q --no-ff --no-edit retry-target
BOUT="$("$STATE" begin retry-integ2 --base "$RB2" --spec docs/spec.md --cap 2 --integration 2>&1)"
CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
append_reply retry-integ2 REQUEST_CHANGES
"$STATE" record retry-integ2 "$CLAIM" >/dev/null 2>&1
BOUT="$("$STATE" begin retry-integ2 --base "$RB2" --spec docs/spec.md --cap 2 --integration 2>&1)"; BRC=$?
[[ "$BRC" -ne 0 && "$BOUT" == *INTEGRATION_REFUSED* ]] \
  && ok "a real REQUEST_CHANGES with rounds left does not reopen the integration exception" || bad "after real RC with rounds left rc=$BRC out=$BOUT"
"$STATE" reset retry-integ2 >/dev/null 2>&1
git checkout -q main

echo "== a claim with no completed dispatch record can be released =="
begin abort-route 1
"$STATE" abort abort-route dispatch-failure "$CLAIM" >/dev/null 2>"$T/err"; ABORT_RC=$?
[[ "$ABORT_RC" -eq 10 \
    && "$(field "$SD/abort-route.review-state" status)" == ABORTED \
    && "$(field "$SD/abort-route.review-state" reason)" == dispatch-failure ]] \
  && ok "abort releases the pending claim with an explicit machine reason" \
  || bad "abort route rc=$ABORT_RC state=$(cat "$SD/abort-route.review-state" 2>/dev/null)"
begin abort-route 1
[[ "$BRC" -eq 0 && -n "$CLAIM" && "$BOUT" == *"attempt=1/1" ]] \
  && ok "a claim with no completed dispatch record consumes no cap" \
  || bad "aborted thread stayed wedged (rc=$BRC err=$(cat "$T/err"))"
"$STATE" reset abort-route >/dev/null 2>&1

begin partial-abort 1
sed 's/^attempts=1$/attempts=0/' "$SD/partial-abort.review-loop" > "$T/partial-loop"
mv "$T/partial-loop" "$SD/partial-abort.review-loop"
"$STATE" abort partial-abort dispatch-failure "$CLAIM" >/dev/null 2>"$T/err"; PARTIAL_ABORT_RC=$?
[[ "$PARTIAL_ABORT_RC" -eq 10 \
    && "$(field "$SD/partial-abort.review-state" status)" == PENDING \
    && "$(field "$SD/partial-abort.review-loop" cap)" == 1 \
    && "$(field "$SD/partial-abort.review-loop" attempts)" == 0 \
    && "$(cat "$T/err")" == *"INVALID_CLAIM_STATE"* ]] \
  && ok "a crash between refund and ABORTED cannot refund the claim twice" \
  || bad "partial abort was not fail-closed (rc=$PARTIAL_ABORT_RC loop=$(cat "$SD/partial-abort.review-loop" 2>/dev/null) err=$(cat "$T/err"))"
begin partial-abort 1
[[ "$BRC" -eq 10 && "$(cat "$T/err")" == *"PENDING"* ]] \
  && ok "a partially published abort blocks a new begin until reset" \
  || bad "partial abort allowed a new begin (rc=$BRC out=$BOUT err=$(cat "$T/err"))"
"$STATE" reset partial-abort >/dev/null 2>&1

begin completed-abort 1
append_reply completed-abort APPROVE
"$STATE" abort completed-abort dispatch-failure "$CLAIM" >/dev/null 2>"$T/err"; COMPLETED_ABORT_RC=$?
[[ "$COMPLETED_ABORT_RC" -eq 10 && "$(field "$SD/completed-abort.review-loop" attempts)" == 1 \
    && "$(cat "$T/err")" == *"ROUND_COMPLETED"* ]] \
  && ok "a completed dispatch cannot use abort to recover its consumed cap" \
  || bad "completed round was refunded (rc=$COMPLETED_ABORT_RC loop=$(cat "$SD/completed-abort.review-loop" 2>/dev/null) err=$(cat "$T/err"))"
"$STATE" reset completed-abort >/dev/null 2>&1

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
CAPMSG="$("$STATE" begin capped --base HEAD --spec docs/spec.md --cap 1 2>&1 >/dev/null)"
[[ "$CAPMSG" == *"At the cap"* && "$CAPMSG" == *required-review.md* && "$CAPMSG" != *"reset workaround"* ]] \
  && ok "the CAP_REACHED refusal points at the owner of the cap rules" || bad "cap refusal: $CAPMSG"
RESMSG="$("$STATE" advisory-check capped 2>&1 >/dev/null)"; RESRC=$?
[[ "$RESMSG" == *REQUIRED_THREAD_RESERVED* && "$RESMSG" != *thread-new* ]] \
  && ok "a reserved thread tells the advisory caller to use another --thread, not to discard state" || bad "reserved refusal: $RESMSG"
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
