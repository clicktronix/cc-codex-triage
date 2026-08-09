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
grep -q 'background_never_satisfies_gate' "$STATE" && ok "background is explicitly non-gating" || bad "background gate rule missing"

echo "== clean candidate and exact approval =="
new_repo "$T/exact"
begin_review review-main >/dev/null
append_verdict review-main APPROVE
bash "$STATE" record review-main foreground >/dev/null
MARKER="$(bash "$STATE" check review-main)"
[[ "$MARKER" == "CC_CODEX_REQUIRED_REVIEW APPROVE thread=review-main head="*" base_sha="*" spec_path=spec.md" ]] && ok "exact foreground APPROVE returns the handoff marker" || bad "exact approval marker malformed: $MARKER"
[[ "$(state_field review-main status)" == APPROVED ]] && ok "machine status APPROVED" || bad "approval status not persisted"
[[ "$(sed -n 's/^head=//p' "$(thread_dir)/review-main.approved")" == "$(git rev-parse HEAD)" ]] && ok "approval bound to HEAD" || bad "approval HEAD mismatch"
[[ "$(sed -n 's/^tree=//p' "$(thread_dir)/review-main.approved")" == "$(git rev-parse 'HEAD^{tree}')" ]] && ok "approval bound to tree" || bad "approval tree mismatch"
[[ "$(sed -n 's/^base_sha=//p' "$(thread_dir)/review-main.approved")" == "$(git rev-parse HEAD)" ]] && ok "approval records canonical base" || bad "approval base mismatch"
[[ "$(sed -n 's/^spec_path=//p' "$(thread_dir)/review-main.approved")" == spec.md ]] && ok "approval records spec" || bad "approval spec mismatch"

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
run_rc bash "$STATE" record review-moving foreground
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
run_rc bash "$STATE" record review-scope foreground
[[ "$RC" -eq 11 && "$(state_field review-scope status)" == STALE ]] && ok "unattributed scope cannot approve" || bad "missing scope metadata accepted (rc=$RC)"

new_repo "$T/reply-spoof"
begin_review review-reply-spoof >/dev/null
fp="$(candidate_field review-reply-spoof fingerprint)"
head="$(candidate_field review-reply-spoof head)"
base="$(candidate_field review-reply-spoof base_sha)"
spec="$(candidate_field review-reply-spoof spec_path)"
printf '[test] mode=initial thread=review-reply-spoof round=1 fp=%s\nPROMPT:\n  review something\nREPLY:\n  BASE_SHA: %s\n  CANDIDATE_SHA: %s\n  SPEC_PATH: %s\n  APPROVE\n---\n' \
  "$fp" "$base" "$head" "$spec" > "$(thread_dir)/review-reply-spoof.log"
run_rc bash "$STATE" record review-reply-spoof foreground
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
run_rc bash "$STATE" record review-duplicate foreground
[[ "$RC" -eq 11 ]] && ok "duplicate required scope is rejected" || bad "duplicate required scope approved"

new_repo "$T/verdict-shape"
begin_review review-contradictory >/dev/null
append_verdict review-contradictory $'REQUEST_CHANGES\n  APPROVE'
run_rc bash "$STATE" record review-contradictory foreground
[[ "$RC" -eq 10 ]] && ok "contradictory verdicts do not approve" || bad "contradictory verdict approved"
begin_review review-trailing >/dev/null
append_verdict review-trailing $'APPROVE\n  Additional trailing analysis.'
run_rc bash "$STATE" record review-trailing foreground
[[ "$RC" -eq 10 ]] && ok "approval must be the final decision" || bad "non-final approval accepted"

new_repo "$T/spec-symlink"
ln -s spec.md linked-spec.md && git add linked-spec.md && git commit -qm symlink
run_rc bash "$STATE" begin review-symlink --base "$TEST_BASE" --spec linked-spec.md --cap 5
[[ "$RC" -eq 13 ]] && ok "required spec symlink is rejected" || bad "spec symlink begin rc=$RC"

new_repo "$T/latest-record"
begin_review review-latest >/dev/null
append_verdict review-latest APPROVE
bash "$STATE" record review-latest foreground >/dev/null
fp="$(candidate_field review-latest fingerprint)"
printf '[test] mode=resume thread=review-latest round=2 fp=%s\nPROMPT:\n  advisory pass without required scope\nREPLY:\n  APPROVE\n---\n' "$fp" >> "$(thread_dir)/review-latest.log"
run_rc bash "$STATE" record review-latest foreground
[[ "$RC" -eq 11 && "$(state_field review-latest status)" == STALE ]] && ok "later advisory pass cannot reuse older required markers" || bad "older required markers were reused (rc=$RC)"

echo "== REQUEST_CHANGES must reach a later APPROVE =="
new_repo "$T/loop"
begin_review review-loop >/dev/null
append_verdict review-loop REQUEST_CHANGES
run_rc bash "$STATE" record review-loop foreground
[[ "$RC" -eq 10 && "$(state_field review-loop status)" == REQUEST_CHANGES ]] && ok "REQUEST_CHANGES blocks" || bad "REQUEST_CHANGES did not block (rc=$RC)"
run_rc bash "$STATE" check review-loop
[[ "$RC" -eq 10 ]] && ok "REQUEST_CHANGES is not approval" || bad "REQUEST_CHANGES check rc=$RC"
printf 'fixed\n' >> code.txt && git add code.txt && git commit -qm fix
begin_review review-loop >/dev/null
append_verdict review-loop APPROVE
bash "$STATE" record review-loop foreground >/dev/null
bash "$STATE" check review-loop >/dev/null && ok "new candidate APPROVE releases" || bad "follow-up APPROVE rejected"

echo "== single-pass and hard stops are never approvals =="
new_repo "$T/non-gates"
begin_review review-bg >/dev/null
append_verdict review-bg APPROVE
run_rc bash "$STATE" record review-bg background
[[ "$RC" -eq 0 && "$(state_field review-bg status)" == BACKGROUND_SINGLE_PASS ]] && ok "background APPROVE is recorded but non-gating" || bad "background result rc=$RC"
run_rc bash "$STATE" check review-bg
[[ "$RC" -eq 10 ]] && ok "background check is refused" || bad "background passed gate rc=$RC"
begin_review review-cap 1 >/dev/null
append_verdict review-cap REQUEST_CHANGES
run_rc bash "$STATE" record review-cap foreground
[[ "$RC" -eq 10 && "$(state_field review-cap status)" == CAP_REACHED ]] && ok "paid-round cap is a hard stop" || bad "cap stop rc=$RC"
begin_review review-diverge >/dev/null
run_rc bash "$STATE" stop review-diverge divergence
[[ "$RC" -eq 10 && "$(state_field review-diverge status)" == DIVERGED ]] && ok "divergence is a hard stop" || bad "divergence stop rc=$RC"

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

git branch legacy-other
git worktree add -q "$T/legacy-other" legacy-other
cd "$T/legacy-other"
GD_OTHER="$(bash "$GATE_DIR_SH")"
[[ ! -e "$GD_OTHER/autoreview.armed" ]] \
  && ok "legacy gate is not cloned into a different-branch worktree" \
  || bad "foreign legacy gate was cloned into another worktree"

summary
