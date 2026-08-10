#!/usr/bin/env bash
# Required /review contract: exact candidate approval, stale-state refusal,
# hard stops, and common-Git state that survives disposable worktrees.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/plugins/cc-codex-triage"
STATE="$PLUGIN/scripts/review-state.sh"
STATE_DIR_SH="$PLUGIN/scripts/state-dir.sh"
GATE_DIR_SH="$PLUGIN/scripts/gate-dir.sh"
. "$ROOT/tests/lib.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/cc-review-contract.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

new_repo() {
  d="$1"; mkdir -p "$d"; cd "$d" || exit 1
  git init -q -b main . && git config user.email test@example.com && git config user.name test
  printf 'base\n' > code.txt
  printf '# Test spec\n' > spec.md
  git add code.txt spec.md && git commit -qm init
  TEST_BASE="$(git rev-parse HEAD)"
  export CC_CODEX_STATE_DIR=.claude/codex-threads
  export CC_CODEX_GATE_DIR=.claude/codex-threads
}

thread_dir() { printf '%s/.claude/codex-threads' "$PWD"; }
candidate_field() { sed -n "s/^$2=//p" "$(thread_dir)/$1.candidate" | head -1; }
state_field() { sed -n "s/^$2=//p" "$(thread_dir)/$1.review-state" | head -1; }
begin_review() { bash "$STATE" begin "$1" --base "$TEST_BASE" --spec spec.md --cap "${2:-5}"; }
claim_for() { candidate_field "$1" claim_token; }
record_review() { bash "$STATE" record "$1" "${2:-foreground}" "$(claim_for "$1")"; }
abort_review() { bash "$STATE" abort "$1" "$2" "$(claim_for "$1")"; }
stop_review() { bash "$STATE" stop "$1" "$2" "$(claim_for "$1")"; }
append_verdict() { # thread verdict
  td="$(thread_dir)"; fp="$(candidate_field "$1" fingerprint)"
  head="$(candidate_field "$1" head)"; base="$(candidate_field "$1" base_sha)"; spec="$(candidate_field "$1" spec_path)"
  printf '[test] mode=resume thread=%s round=1 fp=%s\nPROMPT:\n  REQUIRED_REVIEW\n  BASE_SHA: %s\n  CANDIDATE_SHA: %s\n  SPEC_PATH: %s\nREPLY:\n  %s\n---\n' \
    "$1" "$fp" "$base" "$head" "$spec" "$2" >> "$td/$1.log"
  round="$(cat "$td/$1.rounds" 2>/dev/null | tr -cd '0-9')"; round="${round:-0}"
  printf '%s\n' "$((round + 1))" > "$td/$1.rounds"
}
run_rc() { set +e; "$@" >/dev/null 2>&1; RC=$?; set -e; }
set -e

echo "== manifest contract =="
if grep -q '^disable-model-invocation:' "$PLUGIN/commands/review.md"; then
  bad "review remains user-only"
else
  ok "review is model-invocable"
fi
grep -q -- '--required' "$PLUGIN/commands/review.md" && ok "required mode is documented" || bad "required mode missing"
grep -q 'In `--required` mode, stop here on every `REQUEST_CHANGES`' "$PLUGIN/commands/review.md" \
  && ok "required fixes return to the owning lifecycle" || bad "required review can mutate during review"
grep -qF 'refuted with concrete evidence or explicitly deferred' "$PLUGIN/commands/review.md" \
  && grep -qF 'same immutable candidate' "$PLUGIN/commands/review.md" \
  && ok "required review documents same-candidate disposition without a fake commit" \
  || bad "required review again mandates a code change after every REQUEST_CHANGES"
# The scope block is machine-parsed as the FIRST FOUR prompt lines. A doc that
# says "prepend" twice — once for this block, once for a resume header — lets a
# correct-looking round land as STALE and burn the paid attempt.
grep -qF 'are ALWAYS the first four lines of the prompt body' "$PLUGIN/commands/review.md" \
  && grep -qF 'Nothing may precede them' "$PLUGIN/commands/review.md" \
  && ok "required prompt order is unambiguous" \
  || bad "required scope block order is still ambiguous against prompt_scope_exact"
# A resume does not re-paste the lens contract, and the required parser takes
# the bare token only, so the one line it depends on has to be restated.
grep -qF 'On **every** required round, including a resume, also re-send this single line' \
  "$PLUGIN/commands/review.md" \
  && ok "required rounds restate the exact-verdict line" \
  || bad "a required resume can lose the only output rule its parser enforces"
# prompt_scope_exact requires count[j] == 1: position is not the only rule, and a doc that pins only
# position still lets a quoted SPEC_PATH later in the prompt land STALE.
grep -qF 'exactly once in the whole prompt' "$PLUGIN/commands/review.md" \
  && ok "required prompt documents single-occurrence, not just position" \
  || bad "the exactly-once rule prompt_scope_exact enforces is undocumented"
# The lens contract admits COMMENT; required mode does not. Naming two tokens without saying why
# would be a third, quietly narrower copy of that contract.
grep -qF 'Do not return COMMENT for a required review' "$PLUGIN/commands/review.md" \
  && grep -qF 'not a decision in required mode' "$PLUGIN/commands/review.md" \
  && ok "the restated verdict line explains its narrower token set" \
  || bad "the restated verdict line silently contradicts the lens contract"
# ...and the contract it narrows must still say what it is being narrowed FROM. Pinning only the
# explanation lets the lens block rename a token while this suite stays green.
grep -qF 'exactly APPROVE, REQUEST_CHANGES or' \
  "$PLUGIN/skills/codex-triage/references/review-lenses.md" \
  && grep -qF 'COMMENT' "$PLUGIN/skills/codex-triage/references/review-lenses.md" \
  && ok "the lens contract still admits the token required mode excludes" \
  || bad "the lens verdict tokens moved out from under the required-mode narrowing"
grep -qF 'It counts **`begin` attempts, including the first**' "$PLUGIN/commands/review.md" \
  && grep -qF 'cleared only by `/thread-new <thread>`' "$PLUGIN/commands/review.md" \
  && ok "cap counting and its recovery path are stated where cap is parsed" \
  || bad "cap is still described as repair rounds with no recovery path"
grep -qF '**required-review** state' "$PLUGIN/commands/thread-new.md" \
  && grep -qF 'CAP_REACHED' "$PLUGIN/commands/thread-new.md" \
  && ok "the only exit from a required hard stop is documented where it lives" \
  || bad "thread-new does not document the required-state reset it performs"
grep -qF 'first round pins `base`, `spec`, and `cap`' "$PLUGIN/commands/review.md" \
  && ok "required review documents its pinned paid-round contract" \
  || bad "required review no longer documents base/spec/cap pinning"
grep -q 'background_never_satisfies_gate' "$STATE" && ok "background is explicitly non-gating" || bad "background gate rule missing"
grep -qF -- '--base "$BASE" --spec "$SPEC_PATH" --cap "$CAP"' "$PLUGIN/commands/review.md" \
  && grep -qF 'check "$THREAD"' "$PLUGIN/commands/review.md" \
  && ok "required-review shell examples pass parsed values as quoted data" \
  || bad "required-review documentation reintroduced raw shell placeholders"
grep -qF 'advisory-check "$THREAD"' "$PLUGIN/commands/review.md" \
  && ok "advisory reuse is checked before paid dispatch" || bad "advisory preflight is undocumented"
grep -qF '"$THREAD" --reset-only' "$PLUGIN/commands/thread-new.md" \
  && ok "reset-only command uses the leased driver path" || bad "thread-new still performs split reset commands"

echo "== clean candidate and exact approval =="
new_repo "$T/exact"
EXACT_REPO="$PWD"
begin_review review-main >/dev/null
append_verdict review-main APPROVE
record_review review-main >/dev/null
MARKER="$(bash "$STATE" check review-main)"
[[ "$MARKER" == "CC_CODEX_REQUIRED_REVIEW APPROVE thread=review-main head="*" base_sha="*" spec_path=spec.md" ]] && ok "exact foreground APPROVE returns the handoff marker" || bad "exact approval marker malformed: $MARKER"
[[ "$(state_field review-main status)" == APPROVED ]] && ok "machine status APPROVED" || bad "approval status not persisted"
[[ "$(sed -n 's/^head=//p' "$(thread_dir)/review-main.approved")" == "$(git rev-parse HEAD)" ]] && ok "approval bound to HEAD" || bad "approval HEAD mismatch"
[[ "$(sed -n 's/^tree=//p' "$(thread_dir)/review-main.approved")" == "$(git rev-parse 'HEAD^{tree}')" ]] && ok "approval bound to tree" || bad "approval tree mismatch"
[[ "$(sed -n 's/^base_sha=//p' "$(thread_dir)/review-main.approved")" == "$(git rev-parse HEAD)" ]] && ok "approval records canonical base" || bad "approval base mismatch"
[[ "$(sed -n 's/^spec_path=//p' "$(thread_dir)/review-main.approved")" == spec.md ]] && ok "approval records spec" || bad "approval spec mismatch"
approved_claim="$(claim_for review-main)"
run_rc bash "$STATE" stop review-main cap "$approved_claim"
[[ "$RC" -eq 10 && "$(state_field review-main status)" == APPROVED ]] \
  && ok "a stale claim cannot replace completed approval with a hard stop" \
  || bad "hard stop overwrote a completed approval"
run_rc bash "$STATE" advisory-check review-main
[[ "$RC" -eq 10 && "$(state_field review-main status)" == APPROVED ]] \
  && ok "advisory review is refused before dispatch on a required-review thread" \
  || bad "advisory preflight reused or changed a required-review thread"
run_rc bash "$STATE" advisory-check review-advisory-only
[[ "$RC" -eq 0 ]] && ok "a dedicated advisory thread passes preflight" || bad "fresh advisory preflight rc=$RC"

echo "== partial approval publication never resurrects an older candidate =="
new_repo "$T/partial-publication"
begin_review review-publication >/dev/null
append_verdict review-publication APPROVE
record_review review-publication >/dev/null
APPROVED_HEAD="$(git rev-parse HEAD)"
printf 'candidate b\n' >> code.txt && git add code.txt && git commit -qm candidate-b
begin_review review-publication >/dev/null
append_verdict review-publication APPROVE
MV_STUB="$T/mv-stub"; mkdir -p "$MV_STUB"
cat > "$MV_STUB/mv" <<'MV'
#!/usr/bin/env bash
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in *.approved) exit 91 ;; esac
exec /bin/mv "$@"
MV
chmod +x "$MV_STUB/mv"
set +e
PATH="$MV_STUB:$PATH" record_review review-publication >/dev/null 2>&1
RECORD_RC=$?
set -e
git checkout -q "$APPROVED_HEAD"
set +e
OUT="$(bash "$STATE" check review-publication 2>&1)"; RC=$?
set -e
[[ "$RECORD_RC" -eq 1 && "$RC" -eq 10 ]] \
  && grep -q 'incomplete approval publication' <<<"$OUT" \
  && ok "failed second rename cannot resurrect an older approval" \
  || bad "partial approval publication was accepted (record=$RECORD_RC check=$RC out=$OUT)"
cd "$EXACT_REPO" || exit 1

echo "== code movement invalidates approval =="
printf 'next\n' >> code.txt && git add code.txt && git commit -qm next
run_rc bash "$STATE" check review-main
[[ "$RC" -eq 11 ]] && ok "new commit makes approval stale" || bad "stale approval check rc=$RC"

new_repo "$T/canonical-spec"
bash "$STATE" begin review-canonical --base "$TEST_BASE" --spec ././spec.md --cap 5 >/dev/null
[[ "$(candidate_field review-canonical spec_path)" == spec.md ]] \
  && ok "required spec path is canonicalized" || bad "required spec path kept a leading ./"

echo "== dirty candidates and moving reviews fail closed =="
new_repo "$T/moving"
printf 'dirty\n' >> code.txt
run_rc bash "$STATE" begin review-moving --base "$TEST_BASE" --spec spec.md --cap 5
[[ "$RC" -eq 13 ]] && ok "begin rejects dirty candidate" || bad "dirty begin rc=$RC"
git checkout -q -- code.txt
begin_review review-moving >/dev/null
append_verdict review-moving APPROVE
printf 'moved\n' >> code.txt
run_rc record_review review-moving
[[ "$RC" -eq 11 && "$(state_field review-moving status)" == STALE ]] && ok "moving tree cannot earn approval" || bad "moving tree was not stale (rc=$RC)"

new_repo "$T/tracked-state"
mkdir -p .claude/codex-threads
printf 'tracked\n' > .claude/codex-threads/tracked.txt
git add -f .claude/codex-threads/tracked.txt && git commit -qm tracked-state
run_rc bash "$STATE" begin review-tracked --base "$TEST_BASE" --spec spec.md --cap 5
[[ "$RC" -eq 13 ]] && ok "tracked legacy state invalidates the candidate" || bad "tracked legacy state was excluded"

echo "== required prompt must carry the captured base/spec/candidate =="
new_repo "$T/scope"
begin_review review-scope >/dev/null
fp="$(candidate_field review-scope fingerprint)"
printf '[test] mode=initial thread=review-scope round=1 fp=%s\nPROMPT:\n  review something\nREPLY:\n  APPROVE\n---\n' "$fp" > "$(thread_dir)/review-scope.log"
run_rc record_review review-scope
[[ "$RC" -eq 11 && "$(state_field review-scope status)" == STALE ]] && ok "unattributed scope cannot approve" || bad "missing scope metadata accepted (rc=$RC)"

new_repo "$T/reply-spoof"
begin_review review-reply-spoof >/dev/null
fp="$(candidate_field review-reply-spoof fingerprint)"
head="$(candidate_field review-reply-spoof head)"
base="$(candidate_field review-reply-spoof base_sha)"
spec="$(candidate_field review-reply-spoof spec_path)"
printf '[test] mode=initial thread=review-reply-spoof round=1 fp=%s\nPROMPT:\n  review something\nREPLY:\n  BASE_SHA: %s\n  CANDIDATE_SHA: %s\n  SPEC_PATH: %s\n  APPROVE\n---\n' \
  "$fp" "$base" "$head" "$spec" > "$(thread_dir)/review-reply-spoof.log"
run_rc record_review review-reply-spoof
[[ "$RC" -eq 11 && "$(state_field review-reply-spoof status)" == STALE ]] \
  && ok "reply cannot spoof missing required prompt markers" \
  || bad "reply-only scope markers earned approval (rc=$RC)"

new_repo "$T/duplicate-scope"
begin_review review-duplicate >/dev/null
fp="$(candidate_field review-duplicate fingerprint)"
head="$(candidate_field review-duplicate head)"
base="$(candidate_field review-duplicate base_sha)"
printf '[test] mode=initial thread=review-duplicate round=1 fp=%s\nPROMPT:\n  REQUIRED_REVIEW\n  BASE_SHA: %s\n  BASE_SHA: %s\n  CANDIDATE_SHA: %s\n  SPEC_PATH: spec.md\nREPLY:\n  APPROVE\n---\n' \
  "$fp" "$base" "$base" "$head" > "$(thread_dir)/review-duplicate.log"
run_rc record_review review-duplicate
[[ "$RC" -eq 11 ]] && ok "duplicate required scope is rejected" || bad "duplicate required scope approved"

new_repo "$T/verdict-shape"
begin_review review-contradictory >/dev/null
append_verdict review-contradictory $'REQUEST_CHANGES\n  APPROVE'
run_rc record_review review-contradictory
[[ "$RC" -eq 10 ]] && ok "contradictory verdicts do not approve" || bad "contradictory verdict approved"
begin_review review-trailing >/dev/null
append_verdict review-trailing $'APPROVE\n  Additional trailing analysis.'
run_rc record_review review-trailing
[[ "$RC" -eq 10 ]] && ok "approval must be the final decision" || bad "non-final approval accepted"

new_repo "$T/spec-symlink"
ln -s spec.md linked-spec.md && git add linked-spec.md && git commit -qm symlink
run_rc bash "$STATE" begin review-symlink --base "$TEST_BASE" --spec linked-spec.md --cap 5
[[ "$RC" -eq 13 ]] && ok "required spec symlink is rejected" || bad "spec symlink begin rc=$RC"

new_repo "$T/latest-record"
begin_review review-latest >/dev/null
append_verdict review-latest APPROVE
record_review review-latest >/dev/null
fp="$(candidate_field review-latest fingerprint)"
printf '[test] mode=resume thread=review-latest round=2 fp=%s\nPROMPT:\n  advisory pass without required scope\nREPLY:\n  APPROVE\n---\n' "$fp" >> "$(thread_dir)/review-latest.log"
run_rc record_review review-latest
[[ "$RC" -eq 10 && "$(state_field review-latest status)" == APPROVED ]] \
  && ok "record cannot overwrite an already completed required round" \
  || bad "completed approval was overwritten (rc=$RC)"

new_repo "$T/strict-markdown"
begin_review review-indented >/dev/null
append_verdict review-indented '    APPROVE'
run_rc record_review review-indented
[[ "$RC" -eq 10 ]] && ok "indented code-block verdict is rejected" || bad "indented verdict approved"
begin_review review-fenced >/dev/null
append_verdict review-fenced $'```text\n  APPROVE\n  ```'
run_rc record_review review-fenced
[[ "$RC" -eq 10 ]] && ok "fenced verdict is rejected" || bad "fenced verdict approved"
begin_review review-short-fence >/dev/null
append_verdict review-short-fence $'````text\n  ```\n  APPROVE'
run_rc record_review review-short-fence
[[ "$RC" -eq 10 ]] && ok "short closing fence cannot expose approval" || bad "short fence approved"
begin_review review-fence-text >/dev/null
append_verdict review-fence-text $'```text\n  ```not-a-close\n  APPROVE'
run_rc record_review review-fence-text
[[ "$RC" -eq 10 ]] && ok "fence with trailing text cannot expose approval" || bad "invalid fence approved"
begin_review review-after-verdict >/dev/null
append_verdict review-after-verdict $'APPROVE\n  ```text\n  note after verdict\n  ```'
run_rc record_review review-after-verdict
[[ "$RC" -eq 10 ]] \
  && ok "a fenced block after APPROVE makes it non-final" || bad "post-verdict fence was ignored"

new_repo "$T/non-leading-scope"
begin_review review-non-leading >/dev/null
fp="$(candidate_field review-non-leading fingerprint)"; head="$(candidate_field review-non-leading head)"
base="$(candidate_field review-non-leading base_sha)"
printf '[test] mode=initial thread=review-non-leading round=1 fp=%s\nPROMPT:\n  Intro\n  REQUIRED_REVIEW\n  BASE_SHA: %s\n  CANDIDATE_SHA: %s\n  SPEC_PATH: spec.md\nREPLY:\n  APPROVE\n---\n' \
  "$fp" "$base" "$head" > "$(thread_dir)/review-non-leading.log"
printf '1\n' > "$(thread_dir)/review-non-leading.rounds"
run_rc record_review review-non-leading
[[ "$RC" -eq 11 ]] && ok "required scope must be the leading prompt block" || bad "non-leading scope approved"

echo "== REQUEST_CHANGES must reach a later APPROVE =="
new_repo "$T/loop"
begin_review review-loop >/dev/null
append_verdict review-loop REQUEST_CHANGES
run_rc record_review review-loop
[[ "$RC" -eq 10 && "$(state_field review-loop status)" == REQUEST_CHANGES ]] && ok "REQUEST_CHANGES blocks" || bad "REQUEST_CHANGES did not block (rc=$RC)"
run_rc bash "$STATE" check review-loop
[[ "$RC" -eq 10 ]] && ok "REQUEST_CHANGES is not approval" || bad "REQUEST_CHANGES check rc=$RC"
printf 'fixed\n' >> code.txt && git add code.txt && git commit -qm fix
begin_review review-loop >/dev/null
append_verdict review-loop APPROVE
record_review review-loop >/dev/null
bash "$STATE" check review-loop >/dev/null && ok "new candidate APPROVE releases" || bad "follow-up APPROVE rejected"

echo "== refuted or deferred findings may re-review the same candidate =="
new_repo "$T/same-candidate-loop"
SAME_CANDIDATE_HEAD="$(git rev-parse HEAD)"
begin_review review-same-candidate 3 >/dev/null
append_verdict review-same-candidate REQUEST_CHANGES
run_rc record_review review-same-candidate
[[ "$RC" -eq 10 && "$(state_field review-same-candidate status)" == REQUEST_CHANGES ]] \
  || bad "same-candidate setup did not persist REQUEST_CHANGES"
SAME_BEGIN="$(begin_review review-same-candidate 3)"
[[ "$SAME_BEGIN" == *"attempt=2/3"* \
    && "$(candidate_field review-same-candidate head)" == "$SAME_CANDIDATE_HEAD" ]] \
  && ok "refuted/deferred finding spends a fresh round on the same immutable candidate" \
  || bad "same-candidate re-review reset the loop or changed the candidate: $SAME_BEGIN"
append_verdict review-same-candidate APPROVE
record_review review-same-candidate >/dev/null
[[ "$(git rev-parse HEAD)" == "$SAME_CANDIDATE_HEAD" ]] \
  && bash "$STATE" check review-same-candidate >/dev/null \
  && ok "same-candidate re-review can earn fresh approval without a fake commit" \
  || bad "same-candidate re-review did not earn exact approval"
APPROVED_LOOP="$(cat "$(thread_dir)/review-same-candidate.review-loop")"
run_rc begin_review review-same-candidate 4
[[ "$RC" -eq 10 \
    && "$(state_field review-same-candidate status)" == APPROVED \
    && "$(cat "$(thread_dir)/review-same-candidate.review-loop")" == "$APPROVED_LOOP" ]] \
  && ok "approval does not silently unpin the required-review contract" \
  || bad "approved lifecycle accepted a different cap without reset"

echo "== required-review contract stays pinned until explicit reset =="
new_repo "$T/contract-pinning"
PINNED_BASE="$TEST_BASE"
printf '# Alternate spec\n' > spec-alt.md
git add spec-alt.md && git commit -qm alternate-spec
ALTERNATE_BASE="$(git rev-parse HEAD)"
bash "$STATE" begin review-contract-pinning \
  --base "$PINNED_BASE" --spec spec.md --cap 2 >/dev/null
append_verdict review-contract-pinning REQUEST_CHANGES
run_rc record_review review-contract-pinning
[[ "$RC" -eq 10 ]] || bad "contract-pinning setup did not persist REQUEST_CHANGES"
PINNED_LOOP="$(cat "$(thread_dir)/review-contract-pinning.review-loop")"
PINNED_CANDIDATE="$(cat "$(thread_dir)/review-contract-pinning.candidate")"
for changed_contract in cap spec base; do
  case "$changed_contract" in
    cap)
      run_rc bash "$STATE" begin review-contract-pinning \
        --base "$PINNED_BASE" --spec spec.md --cap 3
      ;;
    spec)
      run_rc bash "$STATE" begin review-contract-pinning \
        --base "$PINNED_BASE" --spec spec-alt.md --cap 2
      ;;
    base)
      run_rc bash "$STATE" begin review-contract-pinning \
        --base "$ALTERNATE_BASE" --spec spec.md --cap 2
      ;;
  esac
  [[ "$RC" -eq 10 \
      && "$(cat "$(thread_dir)/review-contract-pinning.review-loop")" == "$PINNED_LOOP" \
      && "$(cat "$(thread_dir)/review-contract-pinning.candidate")" == "$PINNED_CANDIDATE" \
      && "$(state_field review-contract-pinning status)" == REQUEST_CHANGES ]] \
    && ok "changing pinned $changed_contract fails closed without resetting attempts" \
    || bad "changing pinned $changed_contract replaced required-review lifecycle state"
done
bash "$STATE" reset review-contract-pinning >/dev/null
RESET_BEGIN="$(bash "$STATE" begin review-contract-pinning \
  --base "$ALTERNATE_BASE" --spec spec-alt.md --cap 3)"
[[ "$RESET_BEGIN" == *"attempt=1/3"* \
    && "$(candidate_field review-contract-pinning base_sha)" == "$ALTERNATE_BASE" \
    && "$(candidate_field review-contract-pinning spec_path)" == spec-alt.md ]] \
  && ok "explicit reset permits a new required-review contract" \
  || bad "explicit reset did not permit a new required-review contract: $RESET_BEGIN"

echo "== single-pass and hard stops are never approvals =="
new_repo "$T/non-gates"
begin_review review-bg >/dev/null
append_verdict review-bg APPROVE
run_rc record_review review-bg background
[[ "$RC" -eq 0 && "$(state_field review-bg status)" == BACKGROUND_SINGLE_PASS ]] && ok "background APPROVE is recorded but non-gating" || bad "background result rc=$RC"
run_rc bash "$STATE" check review-bg
[[ "$RC" -eq 10 ]] && ok "background check is refused" || bad "background passed gate rc=$RC"
begin_review review-cap 1 >/dev/null
append_verdict review-cap REQUEST_CHANGES
run_rc record_review review-cap
[[ "$RC" -eq 10 && "$(state_field review-cap status)" == CAP_REACHED ]] && ok "paid-round cap is a hard stop" || bad "cap stop rc=$RC"
begin_review review-diverge >/dev/null
run_rc stop_review review-diverge divergence
[[ "$RC" -eq 10 && "$(state_field review-diverge status)" == DIVERGED ]] && ok "divergence is a hard stop" || bad "divergence stop rc=$RC"
run_rc begin_review review-cap 1
[[ "$RC" -eq 10 ]] && ok "cap cannot be restarted without thread reset" || bad "terminal cap restarted"
run_rc begin_review review-diverge 5
[[ "$RC" -eq 10 ]] && ok "divergence cannot be restarted without thread reset" || bad "terminal divergence restarted"
run_rc record_review review-diverge
[[ "$RC" -eq 10 && "$(state_field review-diverge status)" == DIVERGED ]] \
  && ok "record cannot overwrite terminal divergence" || bad "record overwrote divergence"
printf '%s\n' "$$" > "$(thread_dir)/review-diverge.active"
run_rc bash "$STATE" reset review-diverge
[[ "$RC" -eq 10 && "$(state_field review-diverge status)" == DIVERGED ]] \
  && ok "reset refuses a live foreign dispatch lease" || bad "reset erased a live review"
rm -f "$(thread_dir)/review-diverge.active"
bash "$STATE" reset review-diverge >/dev/null
run_rc begin_review review-diverge 5
[[ "$RC" -eq 0 && "$(state_field review-diverge status)" == PENDING ]] \
  && ok "explicit reset permits a new review after a hard stop" || bad "terminal reset did not reopen review"

new_repo "$T/advisory-stop"
run_rc bash "$STATE" stop review-advisory cap
[[ "$RC" -eq 10 && ! -e "$(thread_dir)/review-advisory.review-state" ]] \
  && ok "advisory hard stop does not poison required-review state" || bad "advisory stop persisted terminal state"
run_rc begin_review review-advisory 1
[[ "$RC" -eq 0 ]] \
  && ok "required review can start after an advisory stop" || bad "advisory stop blocked required review"

echo "== persisted round grammar is shared and never reaches Bash as octal =="
for bad_round in 08 $'1\n2' '7x'; do
  new_repo "$T/round-grammar-${bad_round//[^a-zA-Z0-9]/x}"
  mkdir -p "$(thread_dir)"
  printf '%s' "$bad_round" > "$(thread_dir)/review-round-grammar.rounds"
  begin_review review-round-grammar >/dev/null
  [[ "$(candidate_field review-round-grammar round_before)" == 0 ]] \
    && ok "invalid round '$bad_round' normalizes to decimal zero" \
    || bad "invalid round '$bad_round' leaked into required-review arithmetic"
done

for bad_attempts in 08 12x 12+1; do
  new_repo "$T/loop-invalid-${bad_attempts//[^a-zA-Z0-9]/x}"
  mkdir -p "$(thread_dir)"
  printf 'version=1\nbase_sha=%s\nspec_path=spec.md\ncap=5\nstart_round=0\nattempts=%s\n' \
    "$TEST_BASE" "$bad_attempts" > "$(thread_dir)/review-loop-invalid.review-loop"
  run_rc begin_review review-loop-invalid
  [[ "$RC" -eq 1 && ! -e "$(thread_dir)/review-loop-invalid.candidate" ]] \
    && ok "non-canonical loop attempts '$bad_attempts' fail closed before arithmetic" \
    || bad "non-canonical loop attempts '$bad_attempts' reached required-review arithmetic"
done

new_repo "$T/loop-legacy-attempts"
mkdir -p "$(thread_dir)"
printf 'version=1\nbase_sha=%s\nspec_path=spec.md\ncap=5\nstart_round=0\n' \
  "$TEST_BASE" > "$(thread_dir)/review-loop-legacy.review-loop"
LEGACY_BEGIN="$(begin_review review-loop-legacy)"
[[ "$LEGACY_BEGIN" == *"attempt=1/5"* ]] \
  && ok "legacy loop without attempts derives its paid count from the round counter" \
  || bad "legacy loop without attempts lost backward compatibility: $LEGACY_BEGIN"

new_repo "$T/candidate-octal"
begin_review review-candidate-octal >/dev/null
sed -i.bak 's/^round_before=.*/round_before=08/' "$(thread_dir)/review-candidate-octal.candidate"
rm -f "$(thread_dir)/review-candidate-octal.candidate.bak"
append_verdict review-candidate-octal APPROVE
run_rc record_review review-candidate-octal
[[ "$RC" -eq 11 && "$(state_field review-candidate-octal status)" == STALE ]] \
  && ok "leading-zero candidate counters become stale instead of arithmetic" \
  || bad "leading-zero candidate counter escaped fail-closed validation"

echo "== one required round has one persistent owner =="
new_repo "$T/round-claim"
begin_review review-claim 5 >/dev/null & p1=$!
begin_review review-claim 5 >/dev/null 2>&1 & p2=$!
successes=0
wait "$p1" && successes=$((successes + 1)); wait "$p2" && successes=$((successes + 1))
[[ "$successes" -eq 1 && "$(state_field review-claim status)" == PENDING ]] \
  && ok "concurrent begin permits only one paid round claim" || bad "concurrent round claim count=$successes"
run_rc bash "$STATE" record review-claim foreground bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
[[ "$RC" -eq 10 && "$(state_field review-claim status)" == PENDING ]] \
  && ok "a different invocation token cannot consume the claim" || bad "claim token mismatch was accepted"
printf '%s\n' "$$" > "$(thread_dir)/review-claim.active"
run_rc record_review review-claim
[[ "$RC" -eq 10 && "$(state_field review-claim status)" == PENDING ]] \
  && ok "record cannot consume a live dispatch claim" || bad "record raced a live dispatch"
run_rc abort_review review-claim dispatch-failure
[[ "$RC" -eq 10 && "$(state_field review-claim status)" == PENDING ]] \
  && ok "abort cannot release a live dispatch claim" || bad "abort raced a live dispatch"
printf '%s\n' "$$" > "$(thread_dir)/review-another.active"
run_rc begin_review review-another 1
[[ "$RC" -eq 10 && ! -e "$(thread_dir)/review-another.candidate" ]] \
  && ok "begin refuses a thread with a live dispatch" || bad "begin claimed during a live dispatch"
rm -f "$(thread_dir)/review-claim.active" "$(thread_dir)/review-another.active"
run_rc abort_review review-claim dispatch-failure
[[ "$RC" -eq 10 && "$(state_field review-claim status)" == ABORTED ]] \
  && ok "explicit abort releases a failed dispatch claim" || bad "abort did not release claim"
begin_review review-claim 5 >/dev/null \
  && ok "a new begin is allowed only after explicit abort" || bad "abort did not permit retry"

new_repo "$T/completed-abort"
begin_review review-completed-abort >/dev/null
append_verdict review-completed-abort APPROVE
run_rc abort_review review-completed-abort dispatch-failure
[[ "$RC" -eq 10 && "$(state_field review-completed-abort status)" == PENDING ]] \
  && ok "abort cannot erase a completed dispatch" || bad "completed dispatch was marked ABORTED"
record_review review-completed-abort >/dev/null

new_repo "$T/attempt-cap"
begin_review review-attempt-cap 2 >/dev/null
run_rc abort_review review-attempt-cap dispatch-failure
begin_review review-attempt-cap 2 >/dev/null
run_rc abort_review review-attempt-cap dispatch-failure
run_rc begin_review review-attempt-cap 2
[[ "$RC" -eq 10 && "$(state_field review-attempt-cap status)" == CAP_REACHED \
    && "$(state_field review-attempt-cap gate_eligible)" == false ]] \
  && ok "failed paid attempts cannot bypass the cap" || bad "failed attempts bypassed the cap"

new_repo "$T/round-binding"
begin_review review-round >/dev/null
append_verdict review-round APPROVE
append_verdict review-round APPROVE
run_rc record_review review-round
[[ "$RC" -eq 11 && "$(state_field review-round status)" == STALE ]] \
  && ok "record rejects more than one dispatch after begin" || bad "multiple dispatches satisfied one claim"

new_repo "$T/stale-lock-claim"
mkdir -p "$(thread_dir)/review-stale.review-lock"
printf '99999999\n' > "$(thread_dir)/review-stale.review-lock/owner"
pids=""
for n in 1 2 3 4 5 6 7 8; do
  begin_review review-stale 5 >/dev/null 2>&1 & pids="$pids $!"
done
successes=0
for pid in $pids; do wait "$pid" && successes=$((successes + 1)); done
[[ "$successes" -eq 1 && "$(state_field review-stale status)" == PENDING ]] \
  && ok "stale-lock contention preserves one persistent round claim" \
  || bad "stale-lock contention admitted $successes claims"

echo "== crashed reclaim owners recover instead of deadlocking =="
new_repo "$T/dead-review-reclaimer"
mkdir -p "$(thread_dir)/review-dead-reclaimer.review-lock" \
  "$(thread_dir)/review-dead-reclaimer.review-lock-reclaim"
printf '99999998\n' > "$(thread_dir)/review-dead-reclaimer.review-lock/owner"
printf '99999999\n' > "$(thread_dir)/review-dead-reclaimer.review-lock-reclaim/owner"
run_rc begin_review review-dead-reclaimer 1
[[ "$RC" -eq 0 && "$(state_field review-dead-reclaimer status)" == PENDING ]] \
  && ok "dead review reclaimer is recovered" || bad "dead review reclaimer remained busy (rc=$RC)"

echo "== a resumed pre-token lock loser cannot overwrite the new owner =="
new_repo "$T/pretoken-review-lock"
REAL_MKDIR="$(command -v mkdir)"; REAL_GIT="$(command -v git)"
mkdir -p "$T/pretoken-bin"
printf '#!/usr/bin/env bash\nlast="${!#}"\nif [ -n "${PAUSE_LOCK_SUFFIX:-}" ] && [[ "$last" == *"$PAUSE_LOCK_SUFFIX" ]]; then\n  "%s" "$@" || exit $?\n  : > "$PAUSE_LOCK_MARKER"\n  while [ ! -e "$PAUSE_LOCK_RELEASE" ]; do sleep 0.01; done\n  exit 0\nfi\nexec "%s" "$@"\n' \
  "$REAL_MKDIR" "$REAL_MKDIR" > "$T/pretoken-bin/mkdir"
printf '#!/usr/bin/env bash\nif [ "${PAUSE_GIT_STATUS:-0}" = 1 ] && [ "${1:-}" = status ]; then\n  : > "$PAUSE_GIT_MARKER"\n  while [ ! -e "$PAUSE_GIT_RELEASE" ]; do sleep 0.01; done\nfi\nexec "%s" "$@"\n' \
  "$REAL_GIT" > "$T/pretoken-bin/git"
chmod +x "$T/pretoken-bin/mkdir" "$T/pretoken-bin/git"
rm -f "$T/review-mkdir" "$T/review-mkdir-release" "$T/review-git" "$T/review-git-release"
env PATH="$T/pretoken-bin:$PATH" PAUSE_LOCK_SUFFIX=.review-lock \
  PAUSE_LOCK_MARKER="$T/review-mkdir" PAUSE_LOCK_RELEASE="$T/review-mkdir-release" \
  bash "$STATE" begin review-pretoken --base "$TEST_BASE" --spec spec.md --cap 5 >/dev/null 2>&1 & old_owner=$!
for _i in {1..500}; do [ -e "$T/review-mkdir" ] && break; sleep 0.01; done
touch -t 202001010000 "$(thread_dir)/review-pretoken.review-lock"
env PATH="$T/pretoken-bin:$PATH" PAUSE_GIT_STATUS=1 \
  PAUSE_GIT_MARKER="$T/review-git" PAUSE_GIT_RELEASE="$T/review-git-release" \
  bash "$STATE" begin review-pretoken --base "$TEST_BASE" --spec spec.md --cap 5 >/dev/null 2>&1 & new_owner=$!
for _i in {1..500}; do [ -e "$T/review-git" ] && break; sleep 0.01; done
touch "$T/review-mkdir-release"
set +e; wait "$old_owner"; old_rc=$?; set -e
owner_after_resume="$(cat "$(thread_dir)/review-pretoken.review-lock/owner" 2>/dev/null)"
touch "$T/review-git-release"
set +e; wait "$new_owner"; new_rc=$?; set -e
[[ "$old_rc" -eq 7 && "$new_rc" -eq 0 && "$owner_after_resume" = "$new_owner" ]] \
  && ok "review-lock pre-token loser cannot clobber the reclaimer" \
  || bad "review-lock pre-token race: old=$old_rc new=$new_rc owner=$owner_after_resume expected=$new_owner"

echo "== git inspection failures fail closed =="
new_repo "$T/git-status-failure"
REAL_GIT="$(command -v git)"; mkdir -p "$T/fake-bin"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = status ]; then exit 77; fi\nexec "%s" "$@"\n' "$REAL_GIT" \
  > "$T/fake-bin/git"
chmod +x "$T/fake-bin/git"
run_rc env PATH="$T/fake-bin:$PATH" bash "$STATE" begin review-git-fail --base "$TEST_BASE" --spec spec.md --cap 5
[[ "$RC" -eq 13 ]] && ok "git status failure cannot become a clean candidate" || bad "git status failure passed (rc=$RC)"

echo "== common-Git state survives a disposable worktree =="
unset CC_CODEX_STATE_DIR
unset CC_CODEX_GATE_DIR
new_repo "$T/shared-main"
unset CC_CODEX_STATE_DIR
unset CC_CODEX_GATE_DIR
printf 'legacy-id\n' > /dev/null
git branch temp-review
git worktree add -q "$T/shared-worktree" temp-review
cd "$T/shared-worktree"
SD_WORK="$(bash "$STATE_DIR_SH")"
GD_WORK="$(bash "$GATE_DIR_SH")"
printf 'session-id\n' > "$SD_WORK/review-temp.id"
printf 'branch=temp-review\nthread=review-temp\n' > "$GD_WORK/autoreview.armed"
cd "$T/shared-main"
GD_MAIN="$(bash "$GATE_DIR_SH")"
[[ "$GD_MAIN" != "$GD_WORK" ]] && ok "worktrees have isolated gate directories" || bad "gate directories were shared"
git worktree remove -f "$T/shared-worktree"
SD_MAIN="$(bash "$STATE_DIR_SH" --read-only)"
[[ "$SD_MAIN" == "$SD_WORK" && -f "$SD_MAIN/review-temp.id" ]] && ok "thread survives worktree removal" || bad "shared state was lost"
[[ ! -e "$GD_WORK" ]] && ok "removed worktree does not leave a live local gate" || bad "removed worktree gate survived"

echo "== legacy roots and conflicts fail closed =="
new_repo "$T/legacy-symlink"
unset CC_CODEX_STATE_DIR CC_CODEX_GATE_DIR
mkdir -p "$T/outside-legacy" .claude
rmdir .claude
ln -s "$T/outside-legacy" .claude
mkdir -p "$T/outside-legacy/codex-threads"
printf 'outside\n' > "$T/outside-legacy/codex-threads/review.id"
run_rc bash "$STATE_DIR_SH"
[[ "$RC" -eq 7 && ! -e .git/cc-codex-triage/threads/review.id ]] \
  && ok "symlinked legacy parent is rejected without migration" || bad "legacy parent symlink followed"
run_rc bash "$GATE_DIR_SH"
[[ "$RC" -eq 7 ]] && ok "gate migration also rejects symlinked legacy parent" || bad "gate legacy symlink followed"

new_repo "$T/legacy-entry-symlink"
unset CC_CODEX_STATE_DIR CC_CODEX_GATE_DIR
mkdir -p .claude/codex-threads "$T/outside-entry"
printf 'outside\n' > "$T/outside-entry/session"
ln -s "$T/outside-entry/session" .claude/codex-threads/review.id
run_rc bash "$STATE_DIR_SH" --read-only
[[ "$RC" -eq 7 ]] \
  && ok "read-only state lookup rejects a symlinked legacy entry" || bad "legacy entry symlink accepted"
rm .claude/codex-threads/review.id
ln -s "$T/outside-entry/missing" .claude/codex-threads/review.id
run_rc bash "$STATE_DIR_SH" --read-only
[[ "$RC" -eq 7 ]] \
  && ok "read-only state lookup rejects a dangling legacy entry" || bad "dangling legacy entry accepted"
rm .claude/codex-threads/review.id
printf 'branch=main\nthread=outside\n' > "$T/outside-entry/gate"
ln -s "$T/outside-entry/gate" .claude/codex-threads/autoreview.armed
run_rc bash "$GATE_DIR_SH" --read-only
[[ "$RC" -eq 7 ]] \
  && ok "read-only gate lookup rejects a symlinked legacy entry" || bad "legacy gate entry symlink accepted"

new_repo "$T/shared-entry-symlink"
unset CC_CODEX_STATE_DIR CC_CODEX_GATE_DIR
mkdir -p .claude/codex-threads .git/cc-codex-triage/threads .git/cc-codex-triage/gates "$T/outside-shared"
printf 'legacy\n' > .claude/codex-threads/review.id
ln -s "$T/outside-shared/missing" .git/cc-codex-triage/threads/review.id
run_rc bash "$STATE_DIR_SH"
[[ "$RC" -eq 7 && ! -e "$T/outside-shared/missing" ]] \
  && ok "migration rejects a dangling shared-state symlink" || bad "migration followed shared-state symlink"
printf 'branch=main\nthread=legacy\n' > .claude/codex-threads/autoreview.armed
ln -s "$T/outside-shared/gate" .git/cc-codex-triage/gates/autoreview.armed
run_rc bash "$GATE_DIR_SH"
[[ "$RC" -eq 7 && ! -e "$T/outside-shared/gate" ]] \
  && ok "migration rejects a dangling shared-gate symlink" || bad "migration followed shared-gate symlink"

new_repo "$T/legacy-conflict"
unset CC_CODEX_STATE_DIR CC_CODEX_GATE_DIR
mkdir -p .claude/codex-threads .git/cc-codex-triage/threads
printf 'legacy\n' > .claude/codex-threads/review.id
printf 'shared\n' > .git/cc-codex-triage/threads/review.id
run_rc bash "$STATE_DIR_SH"
[[ "$RC" -eq 7 && "$(cat .git/cc-codex-triage/threads/review.id)" == shared ]] \
  && ok "conflicting legacy state aborts without overwrite" || bad "legacy conflict did not fail closed"
run_rc bash "$STATE_DIR_SH" --read-only
[[ "$RC" -eq 7 ]] && ok "read-only state lookup rejects legacy conflict" || bad "read-only conflict accepted"
printf 'shared\n' > .claude/codex-threads/review.id
bash "$STATE_DIR_SH" >/dev/null \
  && ok "identical legacy and shared state is accepted" || bad "identical legacy state rejected"
mkdir -p .git/cc-codex-triage/gates
printf 'branch=main\nthread=legacy\n' > .claude/codex-threads/autoreview.armed
printf 'branch=main\nthread=shared\n' > .git/cc-codex-triage/gates/autoreview.armed
run_rc bash "$GATE_DIR_SH"
[[ "$RC" -eq 7 && "$(sed -n 's/^thread=//p' .git/cc-codex-triage/gates/autoreview.armed)" == shared ]] \
  && ok "conflicting legacy gate state aborts without overwrite" || bad "legacy gate conflict accepted"
run_rc bash "$GATE_DIR_SH" --read-only
[[ "$RC" -eq 7 ]] \
  && ok "read-only gate lookup rejects legacy conflict" || bad "read-only gate conflict accepted"

echo "== stale migration contention has one safe outcome =="
new_repo "$T/migration-contention"
unset CC_CODEX_STATE_DIR CC_CODEX_GATE_DIR
mkdir -p .claude/codex-threads .git/cc-codex-triage/migration.lock
printf 'legacy-session\n' > .claude/codex-threads/review.id
printf '99999999\n' > .git/cc-codex-triage/migration.lock/owner
migration_successes=0
migration_pids=""
for _i in 1 2 3 4 5 6 7 8; do
  bash "$STATE_DIR_SH" >/dev/null 2>&1 & migration_pids="$migration_pids $!"
done
for _pid in $migration_pids; do
  wait "$_pid" && migration_successes=$((migration_successes + 1))
done
[[ "$migration_successes" -eq 8 \
    && "$(cat .git/cc-codex-triage/threads/review.id 2>/dev/null)" == legacy-session \
    && ! -e .git/cc-codex-triage/migration.lock \
    && ! -e .git/cc-codex-triage/migration-reclaim.lock ]] \
  && ok "concurrent stale-lock reclaim preserves migration state" \
  || bad "migration contention failed: successes=$migration_successes"

echo "== crashed migration reclaimer recovers =="
new_repo "$T/dead-migration-reclaimer"
unset CC_CODEX_STATE_DIR CC_CODEX_GATE_DIR
mkdir -p .claude/codex-threads .git/cc-codex-triage/migration.lock \
  .git/cc-codex-triage/migration-reclaim.lock
printf 'legacy-session\n' > .claude/codex-threads/review.id
printf '99999998\n' > .git/cc-codex-triage/migration.lock/owner
printf '99999999\n' > .git/cc-codex-triage/migration-reclaim.lock/owner
run_rc bash "$STATE_DIR_SH"
[[ "$RC" -eq 0 && "$(cat .git/cc-codex-triage/threads/review.id 2>/dev/null)" == legacy-session \
    && ! -e .git/cc-codex-triage/migration.lock \
    && ! -e .git/cc-codex-triage/migration-reclaim.lock ]] \
  && ok "dead migration reclaimer is recovered" || bad "dead migration reclaimer remained busy (rc=$RC)"

echo "== migration pre-token loser cannot overwrite the new owner =="
new_repo "$T/pretoken-migration-lock"
unset CC_CODEX_STATE_DIR CC_CODEX_GATE_DIR
mkdir -p .claude/codex-threads "$T/pretoken-migration-bin"
printf 'legacy-session\n' > .claude/codex-threads/review.id
REAL_CP="$(command -v cp)"
cp "$T/pretoken-bin/mkdir" "$T/pretoken-migration-bin/mkdir"
printf '#!/usr/bin/env bash\nif [ "${PAUSE_CP:-0}" = 1 ]; then\n  : > "$PAUSE_CP_MARKER"\n  while [ ! -e "$PAUSE_CP_RELEASE" ]; do sleep 0.01; done\nfi\nexec "%s" "$@"\n' \
  "$REAL_CP" > "$T/pretoken-migration-bin/cp"
chmod +x "$T/pretoken-migration-bin/mkdir" "$T/pretoken-migration-bin/cp"
rm -f "$T/migration-mkdir" "$T/migration-mkdir-release" "$T/migration-cp" "$T/migration-cp-release"
env PATH="$T/pretoken-migration-bin:$PATH" PAUSE_LOCK_SUFFIX=/migration.lock \
  PAUSE_LOCK_MARKER="$T/migration-mkdir" PAUSE_LOCK_RELEASE="$T/migration-mkdir-release" \
  bash "$STATE_DIR_SH" >/dev/null 2>&1 & old_migration=$!
for _i in {1..500}; do [ -e "$T/migration-mkdir" ] && break; sleep 0.01; done
touch -t 202001010000 .git/cc-codex-triage/migration.lock
env PATH="$T/pretoken-migration-bin:$PATH" PAUSE_CP=1 \
  PAUSE_CP_MARKER="$T/migration-cp" PAUSE_CP_RELEASE="$T/migration-cp-release" \
  bash "$STATE_DIR_SH" >/dev/null 2>&1 & new_migration=$!
for _i in {1..500}; do [ -e "$T/migration-cp" ] && break; sleep 0.01; done
touch "$T/migration-mkdir-release"
set +e; wait "$old_migration"; old_migration_rc=$?; set -e
migration_owner_after_resume="$(cat .git/cc-codex-triage/migration.lock/owner 2>/dev/null)"
touch "$T/migration-cp-release"
set +e; wait "$new_migration"; new_migration_rc=$?; set -e
[[ "$old_migration_rc" -eq 7 && "$new_migration_rc" -eq 0 \
    && "$migration_owner_after_resume" = "$new_migration" \
    && "$(cat .git/cc-codex-triage/threads/review.id 2>/dev/null)" == legacy-session ]] \
  && ok "migration-lock pre-token loser cannot clobber the reclaimer" \
  || bad "migration pre-token race: old=$old_migration_rc new=$new_migration_rc owner=$migration_owner_after_resume expected=$new_migration"

echo "== historical legacy cleanup archives stay in place =="
new_repo "$T/legacy-archive"
unset CC_CODEX_STATE_DIR CC_CODEX_GATE_DIR
mkdir -p .claude/codex-threads/.archive-20200101-000000-AAAAAA
printf 'archived\n' > .claude/codex-threads/.archive-20200101-000000-AAAAAA/old.log
run_rc bash "$STATE_DIR_SH"
[[ "$RC" -eq 0 && -f .claude/codex-threads/.archive-20200101-000000-AAAAAA/old.log \
    && ! -e .git/cc-codex-triage/threads/.archive-20200101-000000-AAAAAA ]] \
  && ok "legacy cleanup archives are retained without blocking migration" \
  || bad "legacy archive broke or leaked into operational state"

echo "== legacy state migrates without losing the pointer =="
new_repo "$T/legacy"
unset CC_CODEX_STATE_DIR
unset CC_CODEX_GATE_DIR
mkdir -p .claude/codex-threads
printf 'legacy-session\n' > .claude/codex-threads/review-main.id
printf 'branch=main\nthread=review-main\n' > .claude/codex-threads/autoreview.armed
SD="$(bash "$STATE_DIR_SH")"
GD="$(bash "$GATE_DIR_SH")"
[[ "$(cat "$SD/review-main.id" 2>/dev/null)" == legacy-session ]] && ok "legacy pointer migrated" || bad "legacy pointer missing after migration"
[[ -f "$GD/autoreview.armed" && ! -e "$SD/autoreview.armed" ]] \
  && ok "legacy threads and gates migrate to separate ownership" \
  || bad "legacy gate/thread migration mixed ownership"

# Legacy is retained for old plugin compatibility and may legitimately diverge
# after shared state becomes authoritative. Completion markers must make this
# a one-time adoption, not an equality assertion on every future read.
printf 'new-shared-session\n' > "$SD/review-main.id"
printf 'branch=main\nthread=new-shared-thread\n' > "$GD/autoreview.armed"
run_rc bash "$STATE_DIR_SH" --read-only
state_read_rc=$RC
run_rc bash "$GATE_DIR_SH" --read-only
gate_read_rc=$RC
[[ "$state_read_rc" -eq 0 && "$gate_read_rc" -eq 0 \
    && "$(cat "$SD/review-main.id")" == new-shared-session \
    && "$(sed -n 's/^thread=//p' "$GD/autoreview.armed")" == new-shared-thread ]] \
  && ok "post-migration shared state may diverge from retained legacy files" \
  || bad "completed migration was re-compared (state=$state_read_rc gate=$gate_read_rc)"

git branch legacy-other
git worktree add -q "$T/legacy-other" legacy-other
cd "$T/legacy-other"
GD_OTHER="$(bash "$GATE_DIR_SH")"
[[ ! -e "$GD_OTHER/autoreview.armed" ]] \
  && ok "legacy gate is not cloned into a different-branch worktree" \
  || bad "foreign legacy gate was cloned into another worktree"

echo "== /status reports required-gate machine state =="
new_repo "$T/status-gate"
begin_review review-status >/dev/null
# A claim exists before any dispatch, so there is no .id and the thread table
# cannot show it. This is the state a user must see to know a round is in
# flight — and, after a cap, the only state that explains the hard stop.
status_out="$(bash "$PLUGIN/scripts/status.sh" 2>&1)"
printf '%s\n' "$status_out" | grep -q 'Required review gates:' \
  && printf '%s\n' "$status_out" | grep -q 'review-status .*status=PENDING' \
  && printf '%s\n' "$status_out" | grep -q 'claim live' \
  && ok "a pre-dispatch required claim is visible in /status" \
  || bad "required gate state is invisible until a dispatch exists"

# The divergence that costs a paid round: the informational parser accepts a
# decorated verdict, the required parser does not. /status must not report the
# tolerant reading as if the gate had taken it.
append_verdict review-status '## APPROVE'
run_rc record_review review-status
recorded_rc=$RC
gate_status="$(state_field review-status status)"
status_out="$(bash "$PLUGIN/scripts/status.sh" 2>&1)"
[[ "$recorded_rc" -eq 10 && "$gate_status" == NO_DECISION ]] \
  && printf '%s\n' "$status_out" | grep -q 'required gate did not accept it' \
  && ok "a decorated APPROVE is reported as unaccepted, not as approval" \
  || bad "decorated APPROVE reads as approved in /status (rc=$recorded_rc status=$gate_status)"

# A hard stop is the state a user must act on, and the cap can be burned by the very decoration the
# warning above describes — so both must appear together, not one instead of the other.
new_repo "$T/status-hard-stop"
begin_review review-capped 1 >/dev/null
append_verdict review-capped '**APPROVE**'
run_rc record_review review-capped
status_out="$(bash "$PLUGIN/scripts/status.sh" 2>&1)"
[[ "$(state_field review-capped status)" == CAP_REACHED ]] \
  && printf '%s\n' "$status_out" | grep -q 'HARD STOP' \
  && printf '%s\n' "$status_out" | grep -q 'thread-new review-capped' \
  && printf '%s\n' "$status_out" | grep -q 'required gate did not accept it' \
  && ok "a hard stop reports its recovery step and the decoration that caused it" \
  || bad "hard stop or its cause is missing from /status ($(state_field review-capped status))"
# ...and must not advise the one action it just forbade.
printf '%s\n' "$status_out" | grep -q 'Re-run the round' \
  && bad "/status offers a retry under a hard stop" \
  || ok "a hard stop does not also offer a retry"

# A claimed round in flight must not be told to re-run either: the decorated APPROVE it can see
# belongs to the previous round, and the claim is still open.
new_repo "$T/status-pending-retry"
begin_review review-pending >/dev/null
append_verdict review-pending '## APPROVE'
run_rc record_review review-pending
begin_review review-pending >/dev/null
status_out="$(bash "$PLUGIN/scripts/status.sh" 2>&1)"
[[ "$(state_field review-pending status)" == PENDING ]] \
  && printf '%s\n' "$status_out" | grep -q 'has not been' \
  && ! printf '%s\n' "$status_out" | grep -q 'Re-run the round' \
  && ok "a live claim is not told to re-run the round" \
  || bad "PENDING advises a retry while its own round is open"

# An expired pre-dispatch claim is not a live round; cleanup may reap it, and the user needs to know
# which of the two they are looking at.
new_repo "$T/status-expired-claim"
begin_review review-expired >/dev/null
sd="$(thread_dir)"
for f in "$sd/review-expired.candidate" "$sd/review-expired.review-state"; do
  sed 's/^claim_expires_at=.*/claim_expires_at=1/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
status_out="$(bash "$PLUGIN/scripts/status.sh" 2>&1)"
printf '%s\n' "$status_out" | grep -q 'claim EXPIRED' \
  && ok "an expired required claim is distinguished from a live one" \
  || bad "an expired claim still reads as live in /status"

# Read-only is a contract, not a habit: /status must not take the review mutex
# or leave any state behind.
new_repo "$T/status-readonly"
begin_review review-readonly >/dev/null
before="$(ls -A "$(thread_dir)" | sort)"
bash "$PLUGIN/scripts/status.sh" >/dev/null 2>&1
after="$(ls -A "$(thread_dir)" | sort)"
[[ "$before" == "$after" ]] \
  && ok "/status stays read-only over required-gate state" \
  || bad "/status mutated thread state"

summary
