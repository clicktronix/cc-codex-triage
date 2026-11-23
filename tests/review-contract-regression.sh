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
printf 'FROM scratch\n' > Dockerfile
printf 'removed by the candidate\n' > legacy.txt
printf 'a file named by digits\n' > 123
printf 'notes\n' > 'C++.md'
mkdir -p docs/deep && printf 'nested\n' > docs/deep/x.md
printf 'notes\n' > 'docs/Plan Notes.md'
mkdir -p 'app/(auth)/[id]' && printf 'page\n' > 'app/(auth)/[id]/page.tsx'
ln -s docs/deep deep-link
printf '*.ignored\n' > .gitignore && printf 'built\n' > build.ignored
git add .gitignore docs/spec.md Dockerfile legacy.txt 123 'C++.md' docs/deep/x.md 'docs/Plan Notes.md' 'app/(auth)/[id]/page.tsx' deep-link
git commit -qm baseline
BASE0="$(git rev-parse HEAD)"
mkdir -p "$T/other-repo/src dir" && printf 'consumer\n' > "$T/other-repo/api.py" && printf 'consumer\n' > "$T/other-repo/src dir/client.py"
printf 'candidate\n' > app.txt
git rm -q legacy.txt
git add app.txt
git commit -qm candidate
SD="$REPO/.git/cc-codex-triage/threads"

field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# One contract per base and spec: a section that starts on a new thread retires the earlier ones,
# as the CONTRACT_EXISTS refusal tells a caller to.
retire_others() { # thread
  local loop name
  for loop in "$SD"/*.review-loop; do
    [ -f "$loop" ] || continue
    name="$(basename "$loop" .review-loop)"
    [ "$name" = "$1" ] || "$STATE" reset "$name" >/dev/null 2>&1
  done
}

begin() { # thread cap
  retire_others "$1"
  BOUT="$("$STATE" begin "$1" --base "$BASE0" --spec docs/spec.md --cap "${2:-3}" 2>"$T/err")"
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
$("$STATE" footer "$thread")
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
printf '[test]\nPROMPT:\n  x\nREPLY:\n  body\r\n  APPROVE \t\r\n  \t\n---\n' > "$T/invisible.log"
VOUT="$("$VERDICT" "$T/invisible.log")"; VRC=$?
[[ "$VRC" -eq 0 && "$VOUT" == APPROVE ]] \
  && ok "trailing spaces, tabs and CR do not hide a bare verdict" \
  || bad "invisible trailing characters rc=$VRC out=$VOUT"
sed 's/^  APPROVE$/  APPROVE 0123456789abcdef0123456789abcdef01234567/' "$T/strict.log" > "$T/suffixed.log"
"$VERDICT" "$T/suffixed.log" >/dev/null 2>&1 \
  && bad "strict accepted a verdict followed by a hash" \
  || ok "strict rejects a verdict line that carries anything else"
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
Review the candidate.
$("$STATE" footer product-route)"
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
FTR="$("$STATE" footer preflight-route 2>"$T/err")"
[[ "$(printf '%s\n' "$FTR" | wc -l | tr -d ' ')" -eq 4 \
   && "$(printf '%s\n' "$FTR" | tail -n 1)" == "End your message with the verdict ALONE on its own final line — exactly APPROVE or REQUEST_CHANGES." ]] \
  && ok "footer prints the closing instruction, the verdict sentence last" \
  || bad "footer output: $FTR err=$(cat "$T/err")"
FAKE_CODEX_CALLS="$T/calls" CC_DISPATCH_WAIT=10 "$DISPATCH" preflight-route <<< "$HDR
Review the candidate." >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 14 && ! -s "$T/calls" ]] && grep -q "footer preflight-route" "$T/err" \
  && ok "a prompt without the generated footer is refused before Codex is called" \
  || bad "missing footer rc=$RC calls=$(wc -l < "$T/calls") err=$(cat "$T/err")"
FAKE_CODEX_CALLS="$T/calls" CC_DISPATCH_WAIT=10 "$DISPATCH" preflight-route <<< "$HDR
Review the candidate.
$FTR
Return exactly one verdict as the last line: APPROVE <candidate sha> or REQUEST_CHANGES <candidate sha>." >/dev/null 2>&1; RC=$?
[[ "$RC" -eq 14 && ! -s "$T/calls" ]] \
  && ok "an instruction typed after the footer is refused: the generated one has the last word" \
  || bad "typed instruction after the footer rc=$RC"
PF_OUT="$(FAKE_CODEX_CALLS="$T/calls" CC_DISPATCH_WAIT=10 "$DISPATCH" preflight-route <<< "$HDR
Review the candidate.
$FTR" 2>"$T/err")"; RC=$?
[[ "$RC" -eq 0 && -s "$T/calls" && "$PF_OUT" == *APPROVE ]] \
  && ok "the generated header and footer dispatch and the round records" \
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

echo "== only the first blocking verdict without findings is returned =="
begin nf-twice 2
FAKE_REVIEW_BODY="looks wrong somehow" append_reply nf-twice REQUEST_CHANGES
"$STATE" record nf-twice "$CLAIM" >/dev/null 2>&1
begin nf-twice 2
FAKE_REVIEW_BODY="still wrong" append_reply nf-twice REQUEST_CHANGES
NOUT="$("$STATE" record nf-twice "$CLAIM" 2>&1)"; NRC=$?
[[ "$NRC" -eq 10 && "$NOUT" != *NO_FINDINGS* && "$(field "$SD/nf-twice.review-state" status)" == REQUEST_CHANGES \
   && "$(field "$SD/nf-twice.review-state" reason)" == unlocated_findings && "$(field "$SD/nf-twice.review-loop" attempts)" == 1 ]] \
  && ok "the retry that again names no location counts as REQUEST_CHANGES" \
  || bad "second empty findings rc=$NRC out=$NOUT attempts=$(field "$SD/nf-twice.review-loop" attempts)"
begin nf-twice 2
FAKE_REVIEW_BODY="wrong again" append_reply nf-twice REQUEST_CHANGES
"$STATE" record nf-twice "$CLAIM" >/dev/null 2>&1
[[ "$(field "$SD/nf-twice.review-state" status)" == CAP_REACHED && "$(field "$SD/nf-twice.review-loop" attempts)" == 2 ]] \
  && ok "a later one in the same set of rounds counts too and reaches the cap" \
  || bad "third empty findings status=$(field "$SD/nf-twice.review-state" status) attempts=$(field "$SD/nf-twice.review-loop" attempts)"
"$STATE" renew nf-twice --by owner >/dev/null 2>&1
begin nf-twice 2
FAKE_REVIEW_BODY="unclear" append_reply nf-twice REQUEST_CHANGES
"$STATE" record nf-twice "$CLAIM" >/dev/null 2>&1
[[ "$(field "$SD/nf-twice.review-state" status)" == NO_FINDINGS && "$(field "$SD/nf-twice.review-loop" attempts)" == 0 ]] \
  && ok "a renewed set of rounds returns one again" \
  || bad "after renew status=$(field "$SD/nf-twice.review-state" status) attempts=$(field "$SD/nf-twice.review-loop" attempts)"
"$STATE" reset nf-twice >/dev/null 2>&1
begin nf-cap 1
FAKE_REVIEW_BODY="looks wrong somehow" append_reply nf-cap REQUEST_CHANGES
"$STATE" record nf-cap "$CLAIM" >/dev/null 2>&1
begin nf-cap 1
FAKE_REVIEW_BODY="still wrong" append_reply nf-cap REQUEST_CHANGES
NOUT="$("$STATE" record nf-cap "$CLAIM" 2>&1)"; NRC=$?
[[ "$NRC" -eq 10 && "$NOUT" == CAP_REACHED* && "$NOUT" == *"file:line"* && "$(field "$SD/nf-cap.review-state" verdict)" == REQUEST_CHANGES ]] \
  && ok "at the cap the refusal still says the reply located nothing" \
  || bad "unlocated at the cap rc=$NRC out=$NOUT"
"$STATE" reset nf-cap >/dev/null 2>&1

echo "== a location is a tracked file with a line, under any spelling =="
for body in "see localhost:3000" "image node:20 is old" "digest sha256:1 differs" "step:2 fails" "open example.com:3000" \
    "see http://example.com:8080/x" "docs:12 is a directory" "docs/deep:12 is a directory too" "(docs/deep:12) is one in brackets" \
    "$REPO/docs/deep:12 is one by its absolute path" "$(pwd -P)/docs/deep:12 is one by its physical path" "./docs/deep/:12 is one with a dot" \
    "$REPO:12 is the worktree itself" "\`x ? b:1 : c\` is code, not a path" "../other-repo/missing.py:12 does not exist" "$T/other-repo:12 is a directory elsewhere" \
    "/no/such/dir/api.py:12 does not exist" "see other-repo/api.py:12 with no way to find it" \
    "myapp.txt:1 only ends like a tracked name" "untracked.txt:1 was never committed" \
    "missing/app.txt:12 is no path of the tree" "https://example.com/app.txt:12 is a link" \
    "build.ignored:1 is not tracked" "$REPO/build.ignored:1 is not tracked under its absolute path either"; do
  begin loc 2
  FAKE_REVIEW_BODY="$body" append_reply loc REQUEST_CHANGES
  "$STATE" record loc "$CLAIM" >/dev/null 2>&1
  [[ "$(field "$SD/loc.review-state" status)" == NO_FINDINGS ]] \
    && ok "'$body' is not a located finding" || bad "'$body' counted as a location: $(field "$SD/loc.review-state" status)"
  "$STATE" reset loc >/dev/null 2>&1
done
for body in "\`docs/Plan Notes.md:12\` drops a step" "\`docs/Plan Notes.md\`:12 drops a step" "docs/Plan Notes.md:12 drops a step" \
    "Use \`review\` after node:20. Fix \`docs/Plan Notes.md:12\`." "\`first\` and app.txt:1 between two \`spans\`" \
    "./app.txt:1 has the wrong word" "$REPO/app.txt:1 by its absolute path" "C++.md:1 names the wrong standard" \
    "(app.txt:1) has the wrong word" "[app.txt](app.txt:1) has the wrong word" "app/(auth)/[id]/page.tsx:12 skips the guard" \
    "123:1 holds the wrong text" "legacy.txt:1 was still read by the importer" "docs/spec.md:1 requires the opposite" \
    "\`app.txt\`:1 has the wrong word" "deep-link:1 points at the wrong directory" "$REPO/deep-link:1 by its absolute path" \
    "../repo/app.txt:1 reaches the tracked file the long way round" "../other-repo/api.py:12 still calls the removed field" "$T/other-repo/api.py:12 still calls the removed field" \
    "[client.py]($T/other-repo/src dir/client.py:7) reads the old shape" \
    "app.txt:12-15 repeats the block" "app.txt:3:7 has a stray character" "**app.txt**:1 has the wrong word" \
    "\"docs/Plan Notes.md\":12 drops a step"; do
  begin loc 2
  FAKE_REVIEW_BODY="$body" append_reply loc REQUEST_CHANGES
  "$STATE" record loc "$CLAIM" >/dev/null 2>&1
  [[ "$(field "$SD/loc.review-state" status)" == REQUEST_CHANGES ]] \
    && ok "'$body' is a located finding" || bad "'$body' not recognized: $(field "$SD/loc.review-state" status)"
  "$STATE" reset loc >/dev/null 2>&1
done

# A submodule is a directory, and a quote can be the last character of a file name.
LOCREPO="$T/loc-repo"; mkdir -p "$LOCREPO/vendor/widget" && (
  cd "$LOCREPO" && git init -q -b main . && git config user.name test && git config user.email test@example.com \
    && printf 'team\n' > "owners'" && git add "owners'" && git commit -qm base \
    && git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),vendor/widget" && git commit -qm "add a submodule entry"
)
loc_rc() { printf 'REPLY:\n  %s\n  REQUEST_CHANGES\n' "$1" > "$T/loc.log"; (cd "$LOCREPO" && python3 "$PLUGIN/scripts/finding-location.py" "$T/loc.log" HEAD); echo $?; }
[[ "$(loc_rc 'vendor/widget:12 pins an old commit')" == 10 ]] \
  && ok "a submodule entry is not a file" || bad "submodule counted as a location"
[[ "$(loc_rc "\`owners':12\` lists a former member")" == 0 ]] \
  && ok "a name that ends in a quote is matched before quotes are taken for formatting" || bad "owners' not recognized"

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
retire_others integ
BOUT="$("$STATE" begin integ --base "$BASE0" --spec docs/spec.md --cap 2 --integration 2>&1)"; BRC=$?
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

echo "== a renewal can be sized to what was authorized =="
begin renew-sized 3
for _ in 1 2 3; do
  append_reply renew-sized REQUEST_CHANGES
  "$STATE" record renew-sized "$CLAIM" >/dev/null 2>&1
  [[ "$(field "$SD/renew-sized.review-state" status)" == CAP_REACHED ]] || begin renew-sized 3
done
for flag in "--rounds 0" "--rounds 4" "--rounds two" "--grant x"; do
  # shellcheck disable=SC2086 # the flag and its value are two words
  "$STATE" renew renew-sized --by owner $flag >/dev/null 2>&1; RC=$?
  [[ "$RC" -eq 1 && "$(field "$SD/renew-sized.review-state" status)" == CAP_REACHED && "$(field "$SD/renew-sized.review-loop" attempts)" == 3 ]] \
    && ok "renew $flag is refused and renews nothing" || bad "renew $flag rc=$RC"
done
"$STATE" renew renew-sized --by owner --rounds "" >/dev/null 2>&1; RC=$?
[[ "$RC" -eq 1 && "$(field "$SD/renew-sized.review-loop" attempts)" == 3 ]] \
  && ok "an empty --rounds is refused, not read as the whole cap" || bad "renew --rounds '' rc=$RC"
ROUT="$("$STATE" renew renew-sized --by "owner: two more rounds" --rounds 2 2>&1)"; RRC=$?
[[ "$RRC" -eq 0 && "$ROUT" == *"2 round(s)"* && "$(field "$SD/renew-sized.review-loop" attempts)" == 1 && "$(field "$SD/renew-sized.review-loop" cap)" == 3 ]] \
  && ok "renew --rounds 2 keeps the cap pinned and leaves two attempts" || bad "sized renew rc=$RRC out=$ROUT"
begin renew-sized 3
[[ "$BRC" -eq 0 && "$BOUT" == *"attempt=2/3"* ]] && ok "the first renewed round is attempt 2 of 3" || bad "first sized round rc=$BRC out=$BOUT"
append_reply renew-sized REQUEST_CHANGES
"$STATE" record renew-sized "$CLAIM" >/dev/null 2>&1
begin renew-sized 3
append_reply renew-sized REQUEST_CHANGES
"$STATE" record renew-sized "$CLAIM" >/dev/null 2>&1
[[ "$BRC" -eq 0 && "$(field "$SD/renew-sized.review-state" status)" == CAP_REACHED ]] \
  && ok "the second renewed round reaches the cap: two rounds were authorized, two ran" \
  || bad "second sized round rc=$BRC status=$(field "$SD/renew-sized.review-state" status)"
"$STATE" begin renew-sized --base "$BASE0" --spec docs/spec.md >/dev/null 2>&1 \
  && bad "a third round ran on a renewal of two" || ok "a third round is refused"
"$STATE" reset renew-sized >/dev/null 2>&1
USAGE="$("$STATE" 2>&1)"
[[ "$USAGE" == *--integration* && "$USAGE" == *"check <thread>"* && "$USAGE" == *"renew <thread> --by <who> [--rounds N]"* \
   && "$USAGE" == *"footer <thread>"* && "$USAGE" != *--grant* && "$(printf '%s\n' "$USAGE" | wc -l | tr -d ' ')" -eq 1 ]] \
  && ok "the one-line usage names --integration, check, footer and renew --by [--rounds N]" || bad "usage: $USAGE"

echo "== one required contract per base and spec =="
begin first-name 2
BOUT="$("$STATE" begin first-name-v2 --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *CONTRACT_EXISTS* && "$BOUT" == *"thread first-name "* \
   && -z "$(ls "$SD" | grep '^first-name-v2\.')" ]] \
  && ok "a second thread on the same base and spec is refused and leaves no state" \
  || bad "second contract rc=$BRC out=$BOUT files=$(ls "$SD" | grep '^first-name-v2\.' | tr '\n' ' ')"
printf 'other spec\n' > docs/other-spec.md; git add docs/other-spec.md; git commit -qm "another spec"
"$STATE" abort first-name dispatch-failure "$CLAIM" >/dev/null 2>&1
BOUT="$("$STATE" begin other-task --base "$BASE0" --spec docs/other-spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 0 ]] && ok "another spec on the same base is another contract" || bad "other spec rc=$BRC out=$BOUT"
"$STATE" abort other-task dispatch-failure "$(field "$SD/other-task.candidate" claim_token)" >/dev/null 2>&1
"$STATE" reset first-name >/dev/null 2>&1
BOUT="$("$STATE" begin first-name-v2 --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 0 ]] && ok "after the holder is reset the name is free to claim" || bad "claim after reset rc=$BRC out=$BOUT"
"$STATE" reset first-name-v2 >/dev/null 2>&1; "$STATE" reset other-task >/dev/null 2>&1
git reset -q --hard HEAD^
begin spelled 2
[[ "$(field "$SD/spelled.review-loop" spec_path)" == docs/spec.md ]] || bad "setup: spec path of 'spelled'"
BOUT="$("$STATE" begin respelled --base "$BASE0" --spec docs/./spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *CONTRACT_EXISTS* ]] \
  && ok "another spelling of the same spec path is the same contract" || bad "respelled spec rc=$BRC out=$BOUT"
"$STATE" abort spelled dispatch-failure "$CLAIM" >/dev/null 2>&1
BOUT="$("$STATE" begin spelled --base "$BASE0" --spec docs/./spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 0 && "$(field "$SD/spelled.candidate" spec_path)" == docs/spec.md ]] \
  && ok "the claim records the tracked spelling of the spec path" || bad "canonical spec rc=$BRC out=$BOUT"
"$STATE" reset spelled >/dev/null 2>&1
# State written before paths were stored as tracked can hold another spelling of the same file.
begin old-spelling 2
sed 's|^spec_path=.*|spec_path=docs/./spec.md|' "$SD/old-spelling.review-loop" > "$T/loop" && mv "$T/loop" "$SD/old-spelling.review-loop"
BOUT="$("$STATE" begin new-spelling --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *CONTRACT_EXISTS* && "$BOUT" == *"thread old-spelling "* ]] \
  && ok "a holder saved under another spelling still holds the contract" || bad "legacy holder rc=$BRC out=$BOUT"
"$STATE" abort old-spelling dispatch-failure "$CLAIM" >/dev/null 2>&1
rm -f "$SD/old-spelling.candidate" "$SD/old-spelling.review-state"
for typed in docs/spec.md docs/./spec.md; do
  BOUT="$("$STATE" begin old-spelling --base "$BASE0" --spec "$typed" 2>&1)"; BRC=$?
  [[ "$BRC" -eq 0 && "$(field "$SD/old-spelling.review-loop" spec_path)" == docs/./spec.md ]] \
    && ok "its own thread resumes with '$typed' and keeps the saved spelling" || bad "legacy resume '$typed' rc=$BRC out=$BOUT"
  "$STATE" abort old-spelling dispatch-failure "$(field "$SD/old-spelling.candidate" claim_token)" >/dev/null 2>&1
done
"$STATE" reset old-spelling >/dev/null 2>&1
printf 'exit 9\n' > "$T/crash-hook"
CC_REVIEW_STATE_TEST_AFTER_PREP_HOOK="$T/crash-hook" "$STATE" begin old-journal --base "$BASE0" --spec docs/spec.md >/dev/null 2>&1
sed 's|^spec_path=.*|spec_path=docs/./spec.md|' "$SD/old-journal.claim-prep" > "$T/prep" && mv "$T/prep" "$SD/old-journal.claim-prep"
BOUT="$("$STATE" begin old-journal --base "$BASE0" --spec docs/./spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 0 && "$BOUT" == PENDING* && "$(field "$SD/old-journal.candidate" spec_path)" == docs/./spec.md ]] \
  && ok "an interrupted claim journaled under another spelling resumes" || bad "legacy journal rc=$BRC out=$BOUT"
"$STATE" reset old-journal >/dev/null 2>&1
BOUT="$("$STATE" begin holder.claim-prep --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
BOUT="$("$STATE" begin holder --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC2=$?
[[ "$BRC" -eq 0 && "$BRC2" -eq 10 && "$BOUT" == *"thread holder.claim-prep "* ]] \
  && ok "a holder whose name ends like a state file is still found" || bad "suffix-named holder rc=$BRC/$BRC2 out=$BOUT"
"$STATE" reset holder.claim-prep >/dev/null 2>&1
printf 'version=2\nhead=x\ntree=y\nbase_sha=%s\nspec_path=docs/spec.md\ncap=2\n' "$BASE0" > "$SD/publishing.claim-prep"
printf '%s\n' "printf 'version=1\\nbase_sha=%s\\nspec_path=docs/spec.md\\ncap=2\\nattempts=1\\n' '$BASE0' > '$SD/publishing.review-loop'; rm -f '$SD/publishing.claim-prep'" > "$T/publish-hook"
BOUT="$(CC_REVIEW_STATE_TEST_AFTER_JOURNALS_HOOK="$T/publish-hook" "$STATE" begin watcher --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *CONTRACT_EXISTS* && "$BOUT" == *"thread publishing "* && ! -e "$SD/watcher.review-loop" ]] \
  && ok "a holder that publishes while the scan runs is met as a loop" || bad "publish during scan rc=$BRC out=$BOUT"
rm -f "$SD/publishing.review-loop"
begin settled 2
printf 'exit 9\n' > "$T/crash-hook"
CC_REVIEW_STATE_TEST_AFTER_PREP_HOOK="$T/crash-hook" "$STATE" begin crashed --base "$BASE0" --spec docs/spec.md >/dev/null 2>&1
[[ -f "$SD/crashed.claim-prep" ]] || bad "setup: the interrupted claim left no journal"
BOUT="$("$STATE" begin crashed --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *CONTRACT_EXISTS* && "$BOUT" == *"thread settled "* && ! -e "$SD/crashed.claim-prep" && ! -e "$SD/crashed.review-loop" ]] \
  && ok "a first claim interrupted before its check is checked when it is repeated" || bad "recovered claim rc=$BRC out=$BOUT"
"$STATE" abort settled dispatch-failure "$CLAIM" >/dev/null 2>&1; "$STATE" reset settled >/dev/null 2>&1
printf 'version=2\nhead=x\ntree=y\nbase_sha=%s\nspec_path=docs/spec.md\ncap=2\n' "$BASE0" > "$SD/half-claimed.claim-prep"
BOUT="$("$STATE" begin racer --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *CONTRACT_EXISTS* && "$BOUT" == *half-claimed* && ! -e "$SD/racer.claim-prep" ]] \
  && ok "a first claim still in its journal already holds the contract" || bad "journal holder rc=$BRC out=$BOUT"
rm -f "$SD/half-claimed.claim-prep"
printf '%s\n' "printf 'version=2\\nbase_sha=%s\\nspec_path=docs/spec.md\\n' '$BASE0' > '$SD/late.claim-prep'" > "$T/prep-hook"
CC_REVIEW_STATE_TEST_AFTER_PREP_HOOK="$T/prep-hook" "$STATE" begin racer --base "$BASE0" --spec docs/spec.md >"$T/racer.out" 2>&1; echo $? > "$T/racer.rc"
[[ "$(cat "$T/racer.rc")" -eq 10 && "$(cat "$T/racer.out")" == *CONTRACT_EXISTS* && ! -e "$SD/racer.claim-prep" && ! -e "$SD/racer.review-loop" ]] \
  && ok "a claim that meets another journal after writing its own withdraws" \
  || bad "late journal rc=$(cat "$T/racer.rc") out=$(cat "$T/racer.out")"
rm -f "$SD/late.claim-prep"

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
retire_others unicode
for verdict in REQUEST_CHANGES APPROVE; do
  BOUT="$("$STATE" begin unicode --base "$BASE0" --spec docs/spec.md)"
  CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
  HDR="$("$STATE" header unicode)"
  FAKE_REVIEW_BODY="Словарь:1 correct the entry" FAKE_REVIEW_VERDICT="$verdict" "$DISPATCH" unicode --strict <<< "$HDR"$'\n'"$("$STATE" footer unicode)" >/dev/null
  "$STATE" record unicode "$CLAIM" >/dev/null 2>&1
  status="$(field "$SD/unicode.review-state" status)"
  if [ "$verdict" = REQUEST_CHANGES ]; then
    [[ "$status" = REQUEST_CHANGES ]] && ok "Unicode file:line remains actionable" || bad "Unicode finding: $status"
  fi
done
marker="$("$STATE" check unicode)"
expected="CC_CODEX_REQUIRED_REVIEW APPROVE thread=unicode head=$(git rev-parse HEAD) tree=$(git rev-parse 'HEAD^{tree}') base_sha=$BASE0 spec_path=docs/spec.md"
read -ra marker_fields <<< "$marker"
[[ "$marker" = "$expected" && "${#marker_fields[@]}" -eq 7 ]] \
  && ok "the approval marker splits into exactly seven fields" || bad "marker: $marker (${#marker_fields[@]} fields)"

echo "== a spec path with spaces ends the marker as spec_path=<rest of line> =="
SPACED='docs/План работ.md'
BOUT="$("$STATE" begin spaced --base "$BASE0" --spec "$SPACED" 2>"$T/err")"; RC=$?
CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
{ "$STATE" header spaced; "$STATE" footer spaced; } 2>/dev/null | FAKE_REVIEW_VERDICT=APPROVE "$DISPATCH" spaced --strict >/dev/null 2>&1
"$STATE" record spaced "$CLAIM" >/dev/null 2>&1
marker="$("$STATE" check spaced 2>/dev/null)"
prefix="CC_CODEX_REQUIRED_REVIEW APPROVE thread=spaced head=$(git rev-parse HEAD) tree=$(git rev-parse 'HEAD^{tree}') base_sha=$BASE0"
read -ra prefix_fields <<< "${marker%% spec_path=*}"
[[ "$RC" -eq 0 && "$marker" = "$prefix spec_path=$SPACED" && "${#prefix_fields[@]}" -eq 6 ]] \
  && ok "six fields, then the spaced Unicode path to the end of the line" \
  || bad "spaced spec rc=$RC marker=$marker err=$(cat "$T/err")"
for edge in ' lead.md' 'docs/trail.md '; do
  "$STATE" begin edge --base "$BASE0" --spec "$edge" 2>"$T/err"; RC=$?
  [[ "$RC" -eq 1 ]] && grep -q 'start or end with a space' "$T/err" \
    && ok "tracked spec '$edge' is refused: the marker's last field has no outer spaces" \
    || bad "outer-space spec '$edge' rc=$RC err=$(cat "$T/err")"
done
"$STATE" begin newline --base "$BASE0" --spec $'line\nbreak' 2>"$T/err" && bad "multiline spec accepted"
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
# An integration round that located nothing reserved no attempt, so it neither returns one nor
# spends the one this set of rounds may return.
git reset -q --hard HEAD^1
begin integ-refund 2
append_reply integ-refund APPROVE
"$STATE" record integ-refund "$CLAIM" >/dev/null 2>&1
RB3="$(field "$SD/integ-refund.candidate" base_sha)"
git merge -q --no-ff --no-edit retry-target
for expected in NO_FINDINGS REQUEST_CHANGES; do
  BOUT="$("$STATE" begin integ-refund --base "$RB3" --spec docs/spec.md --integration 2>&1)"
  CLAIM="$(sed -n 's/.* claim=\([0-9a-f]*\) .*/\1/p' <<<"$BOUT")"
  FAKE_REVIEW_BODY="no location here" append_reply integ-refund REQUEST_CHANGES
  IMSG="$("$STATE" record integ-refund "$CLAIM" 2>&1)"
  [[ "$(field "$SD/integ-refund.review-state" status)" == "$expected" ]] \
    && ok "an integration reply that locates nothing is $expected" \
    || bad "integration unlocated: wanted $expected, got $(field "$SD/integ-refund.review-state" status) ($BOUT)"
done
[[ "$IMSG" == *"normal round"* && "$IMSG" != *"attempt counts"* ]] \
  && ok "the second one says the integration retry is used, not that an attempt was counted" || bad "integration retry message: $IMSG"
begin integ-refund 2
FAKE_REVIEW_BODY="no location here" append_reply integ-refund REQUEST_CHANGES
"$STATE" record integ-refund "$CLAIM" >/dev/null 2>&1
[[ "$BOUT" == *"attempt=2/2"* && "$(field "$SD/integ-refund.review-state" status)" == NO_FINDINGS && "$(field "$SD/integ-refund.review-loop" attempts)" == 1 ]] \
  && ok "the normal round after it still has the set's one returned attempt" \
  || bad "refund after integration: $BOUT status=$(field "$SD/integ-refund.review-state" status) attempts=$(field "$SD/integ-refund.review-loop" attempts)"
"$STATE" reset integ-refund >/dev/null 2>&1
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

echo "== a round whose prompt lacked the generated footer is not recorded =="
begin footerless 3
FL_BASE="$(field "$SD/footerless.candidate" base_sha)"
"$PLUGIN/scripts/codex-thread.sh" footerless --strict <<EOF >/dev/null
REQUIRED_REVIEW
BASE_SHA: $FL_BASE
CANDIDATE_SHA: $(git rev-parse HEAD)
SPEC_PATH: docs/spec.md
Review the candidate.
EOF
"$STATE" record footerless "$CLAIM" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 11 && "$(field "$SD/footerless.review-state" reason)" == prompt_scope_mismatch ]] \
  && ok "a direct dispatch with the header alone earns no approval" \
  || bad "footerless round rc=$RC reason=$(field "$SD/footerless.review-state" reason)"

echo "== fail closed on candidate and prompt drift =="
begin dirty 3
append_reply dirty APPROVE
printf 'dirty\n' >> app.txt
"$STATE" record dirty "$CLAIM" >/dev/null 2>"$T/err"; RC=$?
[[ "$RC" -eq 11 && "$(field "$SD/dirty.review-state" reason)" == dirty_worktree ]] && grep -q ' M app.txt' "$T/err" \
  && ok "a dirty worktree cannot inherit approval, and the refusal names the path" \
  || bad "dirty candidate rc=$RC reason=$(field "$SD/dirty.review-state" reason)"
git restore app.txt
begin crowded 3
append_reply crowded APPROVE
for n in $(seq 1 25); do : > "left-$n.tmp"; done
"$STATE" record crowded "$CLAIM" >/dev/null 2>"$T/err"
[[ "$(grep -c '^?? left-' "$T/err")" -eq 20 ]] && grep -q '5 more' "$T/err" \
  && ok "a long list of paths is cut with the count of the rest" || bad "crowded worktree: $(cat "$T/err")"
rm -f left-*.tmp

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
"$STATE" begin capped --base "$BASE0" --spec docs/spec.md --cap 1 >/dev/null 2>&1 \
  && bad "a capped thread restarted without reset" \
  || ok "a capped thread requires an explicit reset"
CAPMSG="$("$STATE" begin capped --base "$BASE0" --spec docs/spec.md --cap 1 2>&1 >/dev/null)"
[[ "$CAPMSG" == *"At the cap"* && "$CAPMSG" == *required-review.md* && "$CAPMSG" != *"reset workaround"* ]] \
  && ok "the CAP_REACHED refusal points at the owner of the cap rules" || bad "cap refusal: $CAPMSG"
RESMSG="$("$STATE" advisory-check capped 2>&1 >/dev/null)"; RESRC=$?
[[ "$RESMSG" == *REQUIRED_THREAD_RESERVED* && "$RESMSG" != *thread-new* ]] \
  && ok "a reserved thread tells the advisory caller to use another --thread, not to discard state" || bad "reserved refusal: $RESMSG"
"$STATE" reset capped >/dev/null 2>"$T/err" \
  && ok "reset clears the hard stop" \
  || bad "reset failed: $(cat "$T/err")"

echo "== a refused begin at the cap keeps a recorded approval =="
begin keep 1
append_reply keep APPROVE
"$STATE" record keep "$CLAIM" >/dev/null 2>&1
KEEP_HEAD="$(git rev-parse HEAD)"
BOUT="$("$STATE" begin keep --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
"$STATE" check keep >/dev/null 2>&1; CRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *CAP_REACHED* && "$CRC" -eq 0 ]] \
  && ok "the approved candidate still passes check after the refusal" \
  || bad "refused begin rc=$BRC out=$BOUT check=$CRC status=$(field "$SD/keep.review-state" status)"
ROUT="$("$STATE" renew keep --by owner 2>&1)"; RRC=$?
"$STATE" check keep >/dev/null 2>&1; CRC=$?
[[ "$RRC" -eq 10 && "$ROUT" == *RENEW_REFUSED* && "$CRC" -eq 0 ]] \
  && ok "renew is refused while the approval covers the candidate" \
  || bad "renew over a live approval rc=$RRC out=$ROUT check=$CRC"
printf 'follow-up\n' >> app.txt; git commit -qam "follow-up after the approval"
BOUT="$("$STATE" begin keep --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *CAP_REACHED* && "$(field "$SD/keep.review-state" status)" == APPROVED ]] \
  && ok "a refused begin on a later candidate leaves the approval record an integration round needs" \
  || bad "refused begin on a moved candidate rc=$BRC status=$(field "$SD/keep.review-state" status)"
ROUT="$("$STATE" renew keep --by owner 2>&1)"; RRC=$?
[[ "$RRC" -eq 0 && "$ROUT" == RENEWED* && ! -e "$SD/keep.approved" ]] \
  && ok "an exhausted loop whose approval no longer covers the candidate is renewed" \
  || bad "renew after the candidate moved rc=$RRC out=$ROUT"
begin keep 1
[[ "$BRC" -eq 0 && "$BOUT" == *"attempt=1/1"* ]] \
  && ok "the renewed thread claims the new candidate" || bad "begin after that renew rc=$BRC out=$BOUT"
"$STATE" abort keep dispatch-failure "$CLAIM" >/dev/null 2>&1
"$STATE" reset keep >/dev/null 2>&1
git reset -q --hard "$KEEP_HEAD"

echo "== a base equal to the candidate is refused =="
BOUT="$("$STATE" begin empty-range --base HEAD --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 1 && "$BOUT" == *"nothing to review"* && ! -e "$SD/empty-range.review-loop" && ! -e "$SD/empty-range.candidate" ]] \
  && ok "an empty range earns no claim" || bad "empty range rc=$BRC out=$BOUT"

echo "== a pending claim says where its token is =="
begin lost-token 2
BOUT="$("$STATE" begin lost-token --base "$BASE0" --spec docs/spec.md 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *PENDING* && "$BOUT" == *"lost-token.candidate"* && "$BOUT" == *claim_token* ]] \
  && ok "the PENDING refusal names the claim record" || bad "pending refusal rc=$BRC out=$BOUT"
"$STATE" abort lost-token dispatch-failure "$(field "$SD/lost-token.candidate" claim_token)" >/dev/null 2>&1
[[ "$(field "$SD/lost-token.review-state" status)" == ABORTED ]] \
  && ok "the token read from the claim record releases the claim" || bad "abort by recorded token: $(field "$SD/lost-token.review-state" status)"
"$STATE" reset lost-token >/dev/null 2>&1

echo "== an integration round is exempt only for a merge git reproduces =="
begin integ-check 2
append_reply integ-check APPROVE
"$STATE" record integ-check "$CLAIM" >/dev/null 2>&1
IC_HEAD="$(git rev-parse HEAD)"
git checkout -q -b edit-target
printf 'target moved\n' > edit-target.txt; git add edit-target.txt; git commit -qm "target advances"
git checkout -q main
git merge -q --no-ff --no-commit edit-target >/dev/null 2>&1
printf 'smuggled\n' >> app.txt; git add app.txt; git commit -qm "merge the target plus an edit"
BOUT="$("$STATE" begin integ-check --base "$BASE0" --spec docs/spec.md --integration 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *INTEGRATION_REFUSED* && "$BOUT" == *"normal round"* && "$(field "$SD/integ-check.review-state" status)" == APPROVED ]] \
  && ok "a merge commit that carries an extra edit is not an integration round" \
  || bad "merge plus an edit rc=$BRC out=$BOUT"
git reset -q --hard "$IC_HEAD"
git checkout -q -b conflict-target "$BASE0"
printf 'their candidate\n' > app.txt; git add app.txt; git commit -qm "target adds the same file"
git checkout -q main
git merge -q --no-ff conflict-target >/dev/null 2>&1
printf 'resolved by hand\n' > app.txt; git add app.txt; git commit -qm "merge the target, conflict resolved"
BOUT="$("$STATE" begin integ-check --base "$BASE0" --spec docs/spec.md --integration 2>&1)"; BRC=$?
[[ "$BRC" -eq 10 && "$BOUT" == *INTEGRATION_REFUSED* ]] \
  && ok "a merge with a hand-resolved conflict is not an integration round" \
  || bad "resolved conflict rc=$BRC out=$BOUT"
begin integ-check 2
[[ "$BRC" -eq 0 && "$BOUT" == *"attempt=2/2"* ]] \
  && ok "that merge is reviewed as a normal round" || bad "normal round on the merge rc=$BRC out=$BOUT"
"$STATE" abort integ-check dispatch-failure "$CLAIM" >/dev/null 2>&1
"$STATE" reset integ-check >/dev/null 2>&1
git reset -q --hard "$IC_HEAD"

echo "== concurrent claim and read-only status =="
rm -f "$SD/race."*
retire_others race
("$STATE" begin race --base "$BASE0" --spec docs/spec.md --cap 3 >"$T/race-a" 2>&1; echo $? >"$T/race-a.rc") &
PA=$!
("$STATE" begin race --base "$BASE0" --spec docs/spec.md --cap 3 >"$T/race-b" 2>&1; echo $? >"$T/race-b.rc") &
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
