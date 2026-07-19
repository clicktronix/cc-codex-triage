#!/usr/bin/env bash
# Regression suite for scripts/codex-thread.sh. No real Codex — a stub `codex`
# on PATH emits a canned JSONL stream and writes the -o file.
# Usage: bash tests/driver-regression.sh   (exit 0 = all pass)
set -u

DRIVER="$(cd "$(dirname "$0")/.." && pwd)/plugins/cc-codex-triage/scripts/codex-thread.sh"
[[ -f "$DRIVER" ]] || { echo "driver not found: $DRIVER"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cc-driver-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── stub codex ──────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
cat > "$T/bin/codex" <<'STUB'
#!/usr/bin/env bash
# Fake codex CLI for driver tests. Consumes stdin, writes the -o file, emits a
# thread.started JSONL line. FAKE_CODEX_SPACED=1 emits "key": "value" with a
# space after the colon (the formatting the old awk offsets silently broke on).
# FAKE_CODEX_SLEEP=<s>  sleep before replying (lease-lifecycle tests).
# FAKE_CODEX_BIGERR=1   emit >64KB of stderr noise (diag-cap test).
# FAKE_CODEX_NOUUID=1   exit 0 but emit no recognizable session UUID.
out=""
prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"
done
# record argv so tests can assert the driver forwarded flags to codex
printf '%s\0' "$@" > "${FAKE_CODEX_ARGV:-/dev/null}"
# append one line per invocation so tests can COUNT dispatches (race tests)
[[ -n "${FAKE_CODEX_CALLS:-}" ]] && echo "$$" >> "$FAKE_CODEX_CALLS"
cat >/dev/null
[[ "${FAKE_CODEX_SLEEP:-0}" != "0" ]] && sleep "$FAKE_CODEX_SLEEP"
if [[ "${FAKE_CODEX_BIGERR:-0}" == "1" ]]; then
  awk 'BEGIN{for(i=0;i<2000;i++)print "ERRPAD "i" 0123456789012345678901234567890123456789012345678901234567890123456789"}' >&2
fi
if [[ "${FAKE_CODEX_NOUUID:-0}" == "1" ]]; then
  echo '{"type":"thread.started","no_id_here":"nope"}'
elif [[ "${FAKE_CODEX_SPACED:-0}" == "1" ]]; then
  echo '{"type":"thread.started", "thread_id": "0a1b2c3d-1111-4222-8333-444455556666"}'
else
  echo '{"type":"thread.started","thread_id":"0a1b2c3d-1111-4222-8333-444455556666"}'
fi
[[ -n "$out" ]] && echo "FAKE_REPLY" > "$out"
exit "${FAKE_CODEX_EXIT:-0}"
STUB
chmod +x "$T/bin/codex"
export PATH="$T/bin:$PATH"
unset CLAUDE_PROJECT_DIR CC_CODEX_FLAGS CC_CODEX_TRIAGE_STRICT 2>/dev/null || true

# ── test repo ───────────────────────────────────────────────────────────────
REPO="$T/repo"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.email t@t.t && git config user.name t
echo '.claude/codex-threads/' > .gitignore
echo x > f.txt && git add -A && git commit -qm init

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
SD=.claude/codex-threads
UUID='0a1b2c3d-1111-4222-8333-444455556666'

run() { OUT="$(bash "$DRIVER" "$@" 2>"$T/err" <<< "ping")"; RC=$?; }
# Line immediately following the first exact match of $2 in newline-joined
# argv $1 — used to assert a flag's value is ADJACENT to it, not just present
# somewhere in argv.
next_after() { awk -v flag="$2" 'f{print; exit} $0==flag{f=1}' <<<"$1"; }

echo "== usage errors =="
run "" ; [[ "$RC" -eq 1 ]] && ok "empty thread name -> exit 1" || bad "empty thread name (rc=$RC)"
run 'bad/name'; [[ "$RC" -eq 1 ]] && ok "slash in thread name -> exit 1" || bad "slash thread (rc=$RC)"
run --oneshto t1; [[ "$RC" -eq 1 ]] && grep -q "unknown flag" "$T/err" && ok "mistyped flag rejected, not a thread name" || bad "mistyped flag (rc=$RC)"
run t1 --new --oneshot; [[ "$RC" -eq 1 ]] && ok "--new --oneshot mutually exclusive" || bad "new+oneshot (rc=$RC)"
run t1 --oneshot --require-existing; [[ "$RC" -eq 1 ]] && ok "--oneshot --require-existing mutually exclusive" || bad "oneshot+require (rc=$RC)"

echo "== initial dispatch persists UUID, reply on stdout =="
run t1
[[ "$RC" -eq 0 && "$OUT" == "FAKE_REPLY" ]] && ok "reply echoed" || bad "reply (rc=$RC out=$OUT)"
[[ "$(cat "$SD/t1.id" 2>/dev/null)" == "$UUID" ]] && ok "UUID persisted" || bad "UUID not persisted"
[[ "$(cat "$SD/t1.rounds" 2>/dev/null)" == "1" ]] && ok "rounds=1" || bad "rounds wrong: $(cat "$SD/t1.rounds" 2>/dev/null)"

echo "== --new + --require-existing refused BEFORE destroying the thread =="
run t1 --new --require-existing
[[ "$RC" -eq 1 ]] && ok "combo refused with exit 1" || bad "combo rc=$RC"
[[ "$(cat "$SD/t1.id" 2>/dev/null)" == "$UUID" ]] && ok "existing .id survived the refused combo" || bad ".id was destroyed"

echo "== corrupted .rounds does not kill the script after a paid dispatch =="
printf 'garbage\r\n' > "$SD/t1.rounds"
rm -f "$SD/t1.id"   # force initial mode so the stub runs (resume path would call codex exec resume)
run t1
[[ "$RC" -eq 0 && "$OUT" == "FAKE_REPLY" ]] && ok "reply survives corrupted .rounds" || bad "corrupted .rounds (rc=$RC out=$OUT)"
[[ "$(cat "$SD/t1.rounds")" == "1" ]] && ok "counter reset to 1" || bad "counter: $(cat "$SD/t1.rounds")"

echo "== leading-zero .rounds (octal trap) does not kill the script either =="
echo "08" > "$SD/t1.rounds"
run t1   # resume mode — .id exists from the previous dispatch
[[ "$RC" -eq 0 && "$OUT" == "FAKE_REPLY" ]] && ok "reply survives .rounds=08" || bad ".rounds=08 (rc=$RC out=$OUT)"
[[ "$(cat "$SD/t1.rounds")" == "1" ]] && ok "octal-trap counter reset to 1" || bad "counter: $(cat "$SD/t1.rounds")"

echo "== leading-zero log cap falls back to default instead of erroring =="
echo "prior" > "$SD/t1.log"
CC_CODEX_TRIAGE_LOG_CAP_BYTES=08 run t1
[[ "$RC" -eq 0 && "$OUT" == "FAKE_REPLY" ]] && ok "reply survives LOG_CAP=08" || bad "LOG_CAP=08 (rc=$RC out=$OUT)"
unset CC_CODEX_TRIAGE_LOG_CAP_BYTES

echo "== UUID extraction tolerates spaces in codex JSON output =="
rm -rf "$SD"
FAKE_CODEX_SPACED=1 run t2
[[ "$(cat "$SD/t2.id" 2>/dev/null)" == "$UUID" ]] && ok "spaced JSON still persists the UUID" || bad "spaced JSON broke extraction: '$(cat "$SD/t2.id" 2>/dev/null)'"

echo "== --oneshot leaves no state =="
rm -rf "$SD"
run t3 --oneshot
[[ "$RC" -eq 0 && "$OUT" == "FAKE_REPLY" ]] && ok "oneshot reply" || bad "oneshot (rc=$RC)"
[[ ! -e "$SD" ]] && ok "no state dir created" || bad "state dir exists after oneshot"

echo "== --require-existing with no thread -> exit 6 =="
run t4 --require-existing
[[ "$RC" -eq 6 ]] && ok "exit 6" || bad "require-existing rc=$RC"

echo "== cwd anchor: dispatch from a subdir writes state at the repo root =="
rm -rf "$SD"
mkdir -p sub/deeper && cd sub/deeper
run t5
cd "$REPO"
[[ -f "$SD/t5.id" ]] && ok "state at repo root, not in subdir" || bad "state not at root"
[[ ! -e sub/deeper/.claude ]] && ok "no stray state dir in subdir" || bad "stray state dir in subdir"

echo "== codex failure -> exit 3, diagnostics saved =="
rm -rf "$SD"
FAKE_CODEX_EXIT=7 run t6
[[ "$RC" -eq 3 ]] && ok "exit 3 on codex failure" || bad "codex failure rc=$RC"
[[ -f "$SD/t6.last-error.jsonl" ]] && ok "diagnostics saved" || bad "no diagnostics file"

echo "== --model / --effort forwarded on initial dispatch =="
rm -rf "$SD"; export FAKE_CODEX_ARGV="$T/argv"
run t7 --model gpt-5.5 --effort high
argv="$(tr '\0' '\n' < "$T/argv")"
grep -qx -- '-m' <<<"$argv" && grep -qx 'gpt-5.5' <<<"$argv" && ok "--model -> -m gpt-5.5" || bad "--model not forwarded"
grep -qx 'model_reasoning_effort=high' <<<"$argv" && ok "--effort -> -c model_reasoning_effort=high" || bad "--effort not forwarded"

echo "== invalid --effort rejected (exit 1) =="
run t7 --effort turbo; [[ "$RC" -eq 1 ]] && ok "bad effort -> exit 1" || bad "bad effort rc=$RC"

echo "== --schema missing file rejected (exit 1) =="
run t8 --schema "$T/nope.json"; [[ "$RC" -eq 1 ]] && ok "missing schema -> exit 1" || bad "missing schema rc=$RC"

echo "== --schema forwarded as --output-schema =="
echo '{}' > "$T/s.json"; rm -rf "$SD"
run t9 --schema "$T/s.json"
argv="$(tr '\0' '\n' < "$T/argv")"
grep -qx -- '--output-schema' <<<"$argv" && ok "--schema -> --output-schema" || bad "--schema not forwarded"
[[ "$(next_after "$argv" '--output-schema')" == "$T/s.json" ]] && ok "schema path immediately follows --output-schema (initial)" || bad "schema path not adjacent to --output-schema (initial)"

echo "== model/effort IGNORED + WARN on resume; schema IS forwarded on resume =="
rm -rf "$SD"; run t10                       # initial creates .id
FAKE_CODEX_ARGV="$T/argv2" run t10 --model gpt-5.5
argv2="$(tr '\0' '\n' < "$T/argv2")"
grep -qx 'gpt-5.5' <<<"$argv2" && bad "model leaked into resume" || ok "model not forwarded on resume"
grep -qi 'ignored on resume' "$T/err" && ok "resume WARN emitted for model" || bad "no resume WARN"
FAKE_CODEX_ARGV="$T/argv2b" run t10 --effort high
argv2b="$(tr '\0' '\n' < "$T/argv2b")"
grep -qx 'model_reasoning_effort=high' <<<"$argv2b" && bad "effort leaked into resume" || ok "effort not forwarded on resume"
grep -qi 'ignored on resume' "$T/err" && ok "resume WARN emitted for effort" || bad "no resume WARN for effort"
echo '{}' > "$T/s.json"
FAKE_CODEX_ARGV="$T/argv3" run t10 --schema "$T/s.json"
argv3="$(tr '\0' '\n' < "$T/argv3")"
grep -qx -- '--output-schema' <<<"$argv3" && ok "--schema forwarded on resume" || bad "schema dropped on resume"
[[ "$(next_after "$argv3" '--output-schema')" == "$T/s.json" ]] && ok "schema path immediately follows --output-schema (resume)" || bad "schema path not adjacent to --output-schema (resume)"
grep -qi 'ignored on resume' "$T/err" && bad "schema wrongly warned as ignored" || ok "no false resume WARN for schema"
unset FAKE_CODEX_ARGV

echo "== exit 7: persistent dispatch from a non-repo cwd, no env =="
mkdir -p "$T/norepo"
NOREPO="$(cd "$T/norepo" && pwd)"   # canonicalized: the driver reports bash's normalized $PWD
cd "$NOREPO"
run a1
[[ "$RC" -eq 7 ]] && ok "non-repo cwd -> exit 7" || bad "non-repo cwd rc=$RC"
grep -q "not inside a git repository" "$T/err" && grep -qF "$NOREPO" "$T/err" && ok "message names the candidate dir" || bad "exit-7 message wrong: $(cat "$T/err")"
[[ ! -e "$NOREPO/.claude" ]] && ok "no .claude created in non-repo dir" || bad ".claude created in non-repo dir"
cd "$REPO"

echo "== exit 7: CLAUDE_PROJECT_DIR -> existing NON-repo dir =="
export CLAUDE_PROJECT_DIR="$NOREPO"
run a2
unset CLAUDE_PROJECT_DIR
[[ "$RC" -eq 7 ]] && ok "env candidate non-repo -> exit 7" || bad "env non-repo rc=$RC"
[[ -z "$(ls -A "$NOREPO")" ]] && ok "nothing written to the candidate dir" || bad "candidate dir not empty: $(ls -A "$NOREPO")"

echo "== exit 7: CLAUDE_PROJECT_DIR -> nonexistent path =="
export CLAUDE_PROJECT_DIR="$T/does-not-exist"
run a3
unset CLAUDE_PROJECT_DIR
[[ "$RC" -eq 7 ]] && ok "env candidate nonexistent -> exit 7" || bad "env nonexistent rc=$RC"

echo "== CLAUDE_PROJECT_DIR -> repo SUBDIR resolves state to the repo root =="
rm -rf "$SD"; mkdir -p "$REPO/sub/deeper"
cd "$T"
export CLAUDE_PROJECT_DIR="$REPO/sub/deeper"
run a4
unset CLAUDE_PROJECT_DIR
cd "$REPO"
[[ "$RC" -eq 0 && -f "$SD/a4.id" ]] && ok "state anchored at repo root from subdir candidate" || bad "subdir candidate (rc=$RC)"
[[ ! -e "$REPO/sub/deeper/.claude" ]] && ok "no split state under the subdir" || bad "state split into subdir"

echo "== --oneshot from a non-repo dir still dispatches, keeps no state =="
cd "$NOREPO"
run a5 --oneshot
cd "$REPO"
[[ "$RC" -eq 0 && "$OUT" == "FAKE_REPLY" ]] && ok "oneshot works outside a repo" || bad "oneshot non-repo (rc=$RC out=$OUT)"
[[ ! -e "$NOREPO/.claude" ]] && ok "no state dir created by oneshot" || bad "state dir created by oneshot"

echo "== failure diag is capped to the last 64KB =="
rm -rf "$SD"
FAKE_CODEX_EXIT=7 FAKE_CODEX_BIGERR=1 run a6
[[ "$RC" -eq 3 ]] && ok "oversized-stderr failure -> exit 3" || bad "bigerr rc=$RC"
SZ="$(wc -c < "$SD/a6.last-error.jsonl" 2>/dev/null | tr -d ' ')"
[[ -n "$SZ" && "$SZ" -gt 0 && "$SZ" -le 65536 ]] && ok "diag capped ($SZ bytes <= 65536)" || bad "diag size: ${SZ:-missing}"

echo "== success removes the previous last-error diag =="
FAKE_CODEX_EXIT=7 run a7
[[ -f "$SD/a7.last-error.jsonl" ]] && ok "failure stored a diag" || bad "no diag after failure"
run a7
[[ "$RC" -eq 0 && ! -e "$SD/a7.last-error.jsonl" ]] && ok "diag removed on next success" || bad "stale diag survived success (rc=$RC)"

echo "== exit 0 without a UUID writes a FRESH diag (deletion precedes extraction) =="
rm -rf "$SD"; mkdir -p "$SD"
printf 'STALE_DIAG\n' > "$SD/a8.last-error.jsonl"
FAKE_CODEX_NOUUID=1 run a8
[[ "$RC" -eq 0 ]] && ok "no-UUID dispatch still exits 0" || bad "no-uuid rc=$RC"
[[ -f "$SD/a8.last-error.jsonl" ]] && ok "fresh diag exists after the dispatch" || bad "diag missing — deletion ran after extraction"
grep -q 'no_id_here' "$SD/a8.last-error.jsonl" 2>/dev/null && ok "diag holds the fresh stream, not the stale one" || bad "diag content stale"
[[ ! -e "$SD/a8.id" ]] && ok "no .id persisted without a UUID" || bad ".id persisted without UUID"

echo "== lease: .active holds the dispatching PID during dispatch, gone after =="
rm -rf "$SD"
FAKE_CODEX_SLEEP=2 bash "$DRIVER" a9 <<< "ping" > "$T/a9.out" 2>&1 &
DRV=$!
i=0; while [[ ! -f "$SD/a9.active" && $i -lt 40 ]]; do sleep 0.1; i=$((i+1)); done
[[ -f "$SD/a9.active" ]] && ok "lease appeared during dispatch" || bad "lease never appeared"
[[ "$(cat "$SD/a9.active" 2>/dev/null)" == "$DRV" ]] && ok "lease holds the dispatching PID" || bad "lease pid: '$(cat "$SD/a9.active" 2>/dev/null)' expected $DRV"
wait "$DRV"; RC=$?
[[ "$RC" -eq 0 && ! -e "$SD/a9.active" ]] && ok "lease removed after successful exit" || bad "lease left after success (rc=$RC)"
FAKE_CODEX_EXIT=7 run a9b
[[ "$RC" -eq 3 && ! -e "$SD/a9b.active" ]] && ok "lease removed after failed exit" || bad "lease left after failure (rc=$RC)"

echo "== lease removal is ownership-checked: a foreign lease survives =="
rm -rf "$SD"
FAKE_CODEX_SLEEP=2 bash "$DRIVER" a10 <<< "ping" > "$T/a10.out" 2>&1 &
DRV=$!
i=0; while [[ ! -f "$SD/a10.active" && $i -lt 40 ]]; do sleep 0.1; i=$((i+1)); done
# Simulate a takeover after the owner is presumed dead (a LIVE second dispatch
# is refused with exit 10 now, so an overwrite can only follow a dead owner).
printf '%s' "99999999" > "$SD/a10.active"
wait "$DRV"
[[ -f "$SD/a10.active" && "$(cat "$SD/a10.active")" == "99999999" ]] && ok "foreign lease NOT removed by the earlier owner" || bad "foreign lease removed or altered"
rm -f "$SD/a10.active"

echo "== exclusive lease: live foreign lease refuses the dispatch (exit 10) =="
rm -rf "$SD"; mkdir -p "$SD"
sleep 30 & FL=$!
printf '%s' "$FL" > "$SD/b1.active"
export FAKE_CODEX_ARGV="$T/b1argv"; rm -f "$T/b1argv"
run b1
[[ "$RC" -eq 10 ]] && ok "busy thread -> exit 10" || bad "busy rc=$RC err=$(cat "$T/err")"
grep -q "busy (active dispatch pid=$FL)" "$T/err" && ok "busy message names the owning pid" || bad "busy message: $(cat "$T/err")"
[[ "$(cat "$SD/b1.active" 2>/dev/null)" == "$FL" ]] && ok "foreign lease untouched by the refusal" || bad "lease touched: '$(cat "$SD/b1.active" 2>/dev/null)'"
[[ ! -e "$T/b1argv" ]] && ok "stub codex never ran for the refused dispatch" || bad "dispatch ran despite the live lease"
[[ ! -f "$SD/b1.log" ]] && ok "no thread state written by the refused dispatch" || bad "refused dispatch wrote thread state"
run b1 --detach
[[ "$RC" -eq 10 ]] && ok "busy thread -> exit 10 on --detach too (launcher pre-check)" || bad "detach busy rc=$RC err=$(cat "$T/err")"
kill "$FL" 2>/dev/null; wait "$FL" 2>/dev/null
unset FAKE_CODEX_ARGV

echo "== exclusive lease: dead-PID lease is overwritten, dispatch proceeds =="
sleep 0 & DP=$!; wait "$DP" 2>/dev/null
printf '%s' "$DP" > "$SD/b2.active"
FAKE_CODEX_SLEEP=2 bash "$DRIVER" b2 <<< "ping" > "$T/b2.out" 2>&1 &
DRV=$!
i=0; while [[ "$(cat "$SD/b2.active" 2>/dev/null)" != "$DRV" && $i -lt 40 ]]; do sleep 0.1; i=$((i+1)); done
[[ "$(cat "$SD/b2.active" 2>/dev/null)" == "$DRV" ]] && ok "dead lease replaced by the new owner's PID" || bad "dead lease not replaced: '$(cat "$SD/b2.active" 2>/dev/null)'"
wait "$DRV"; RC=$?
[[ "$RC" -eq 0 && ! -e "$SD/b2.active" ]] && ok "dispatch proceeded over the dead lease and released it" || bad "dead-lease dispatch rc=$RC"

echo "== lease acquisition refuses a directory <thread>.active =="
mkdir -p "$SD/c1.active"
export FAKE_CODEX_ARGV="$T/c1argv"; rm -f "$T/c1argv"
run c1
[[ "$RC" -eq 10 ]] && ok "directory lease -> exit 10" || bad "dir-lease rc=$RC err=$(cat "$T/err")"
grep -q 'not a regular file' "$T/err" && ok "clear error names the non-regular lease" || bad "dir-lease message: $(cat "$T/err")"
[[ ! -e "$T/c1argv" ]] && ok "no dispatch happened (stub never ran)" || bad "dispatch ran despite the directory lease"
[[ -d "$SD/c1.active" && -z "$(ls -A "$SD/c1.active" 2>/dev/null)" ]] && ok "directory lease left in place, nothing moved inside it" || bad "directory lease altered: $(ls -A "$SD/c1.active" 2>/dev/null)"
[[ -z "$(ls "$SD"/c1.active.tmp.* 2>/dev/null)" ]] && ok "no lease tmp left behind" || bad "lease tmp leaked: $(ls "$SD"/c1.active.tmp.* 2>/dev/null)"
unset FAKE_CODEX_ARGV
rm -rf "$SD/c1.active"

echo "== lease tmp never left behind (success + injected failure) =="
rm -rf "$SD"
run c2
[[ "$RC" -eq 0 ]] && ok "baseline success dispatch" || bad "c2 rc=$RC"
[[ -z "$(ls "$SD"/c2.active.tmp.* 2>/dev/null)" ]] && ok "no lease tmp after success" || bad "lease tmp left after success"
FAKE_CODEX_EXIT=7 run c3
[[ "$RC" -eq 3 ]] && ok "injected failure dispatch" || bad "c3 rc=$RC"
[[ -z "$(ls "$SD"/c3.active.tmp.* 2>/dev/null)" ]] && ok "no lease tmp after failure" || bad "lease tmp left after failure"

echo "== --detach --oneshot mutually exclusive =="
run d0 --detach --oneshot
[[ "$RC" -eq 1 ]] && ok "detach+oneshot -> exit 1" || bad "detach+oneshot rc=$RC"

echo "== detach: handshake, child-owned lease, reply lands, tmpfiles gone =="
rm -rf "$SD"
mkdir -p "$T/dtmp1"
TMPDIR="$T/dtmp1" FAKE_CODEX_SLEEP=2 run d1 --detach
[[ "$RC" -eq 0 ]] && ok "parent returns 0 after the handshake" || bad "detach parent rc=$RC err=$(cat "$T/err")"
grep -q '^DETACHED pid=' <<<"$OUT" && grep -q 'output=d1.detach-output' <<<"$OUT" && ok "DETACHED line names pid + sidecar" || bad "DETACHED line wrong: $OUT"
DCHILD="$(sed -n 's/^DETACHED pid=\([0-9]*\).*/\1/p' <<<"$OUT")"
# The parent has exited but the child still sleeps inside the stub: the lease
# must hold the CHILD's PID (the launcher acquired none).
[[ -f "$SD/d1.active" && "$(cat "$SD/d1.active" 2>/dev/null)" == "$DCHILD" ]] && ok "lease holds the CHILD's PID while it dispatches" || bad "lease: '$(cat "$SD/d1.active" 2>/dev/null)' expected child $DCHILD"
i=0; while ! grep -q FAKE_REPLY "$SD/d1.log" 2>/dev/null && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
grep -q FAKE_REPLY "$SD/d1.log" 2>/dev/null && ok "reply landed in the thread log" || bad "reply never landed"
i=0; while [[ -e "$SD/d1.active" && $i -lt 50 ]]; do sleep 0.1; i=$((i+1)); done
[[ ! -e "$SD/d1.active" ]] && ok "lease released after the child finished" || bad "lease still present after completion"
[[ "$(cat "$SD/d1.rounds" 2>/dev/null)" == "1" ]] && ok "rounds bumped exactly once" || bad "rounds: $(cat "$SD/d1.rounds" 2>/dev/null)"
[[ -f "$SD/d1.detach-output" ]] && ok "sidecar exists" || bad "no sidecar"
i=0; while [[ -n "$(ls -A "$T/dtmp1" 2>/dev/null)" && $i -lt 50 ]]; do sleep 0.1; i=$((i+1)); done
[[ -z "$(ls -A "$T/dtmp1" 2>/dev/null)" ]] && ok "prompt + ready tmpfiles gone" || bad "orphan tmpfiles: $(ls -A "$T/dtmp1")"

echo "== detach: dispatch survives a group-kill of the launcher's session =="
rm -rf "$SD"
cat > "$T/wrap.sh" <<WRAP
#!/usr/bin/env bash
export FAKE_CODEX_SLEEP=3
bash "$DRIVER" d2 --detach <<< "ping" > "$T/d2.out" 2>&1
echo \$? > "$T/d2.rc"
sleep 30
WRAP
chmod +x "$T/wrap.sh"
# The wrapper itself is session-isolated (same setsid/python trick) so this
# harness is NOT in the process group we are about to kill.
if command -v setsid >/dev/null 2>&1; then
  setsid bash "$T/wrap.sh" >/dev/null 2>&1 &
else
  python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' bash "$T/wrap.sh" >/dev/null 2>&1 &
fi
WPID=$!
disown   # drop the wrapper from the job table — its kill below is deliberate
i=0; while [[ ! -s "$T/d2.rc" && $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
[[ "$(cat "$T/d2.rc" 2>/dev/null)" == "0" ]] && ok "detach parent exited 0 inside the wrapper" || bad "wrapper parent rc: '$(cat "$T/d2.rc" 2>/dev/null)' out: $(cat "$T/d2.out" 2>/dev/null)"
kill -TERM -"$WPID" 2>/dev/null || true
i=0; while ! grep -q FAKE_REPLY "$SD/d2.log" 2>/dev/null && [[ $i -lt 150 ]]; do sleep 0.1; i=$((i+1)); done
grep -q FAKE_REPLY "$SD/d2.log" 2>/dev/null && ok "reply landed despite the wrapper-pgid kill" || bad "reply lost after group kill"

echo "== detach: no setsid AND no python3 -> exit 8, ZERO state =="
rm -rf "$SD"
mkdir -p "$T/isolbin" "$T/dtmp3"
# Minimal PATH farm: everything the driver touches BEFORE the isolator
# preflight, but neither setsid nor python3.
for tool in bash git cat rm ls mkdir sed grep sleep env xcrun; do
  p="$(command -v "$tool" 2>/dev/null || true)"; [[ -n "$p" ]] && ln -sf "$p" "$T/isolbin/$tool"
done
TMPDIR="$T/dtmp3" PATH="$T/bin:$T/isolbin" run d3 --detach
[[ "$RC" -eq 8 ]] && ok "no isolator -> exit 8" || bad "no-isolator rc=$RC err=$(cat "$T/err")"
grep -q 'setsid' "$T/err" && grep -q 'python3' "$T/err" && ok "message names both isolators" || bad "exit-8 message wrong: $(cat "$T/err")"
[[ ! -e "$SD" ]] && ok "zero state: no state dir" || bad "state dir created: $(ls -A "$SD" 2>/dev/null)"
[[ -z "$(ls -A "$T/dtmp3" 2>/dev/null)" ]] && ok "zero state: no lease, no orphan tmpfiles" || bad "tmpfiles left: $(ls -A "$T/dtmp3")"

echo "== detach: setsid hidden, python3 present -> python isolator end-to-end =="
rm -rf "$SD"
mkdir -p "$T/nosetsid"
# Full PATH farm for a complete dispatch, minus setsid (exercises the python
# isolator even on Linux CI where setsid exists).
for tool in bash git python3 cat mktemp sed awk date wc tr mv rm mkdir rmdir stat touch tail grep diff sleep ls env dirname xcrun; do
  p="$(command -v "$tool" 2>/dev/null || true)"; [[ -n "$p" ]] && ln -sf "$p" "$T/nosetsid/$tool"
done
PATH="$T/bin:$T/nosetsid" run d4 --detach
[[ "$RC" -eq 0 ]] && grep -q '^DETACHED pid=' <<<"$OUT" && ok "python-isolator handshake completed" || bad "python isolator rc=$RC out=$OUT err=$(cat "$T/err")"
i=0; while ! grep -q FAKE_REPLY "$SD/d4.log" 2>/dev/null && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
grep -q FAKE_REPLY "$SD/d4.log" 2>/dev/null && ok "reply landed via the python isolator" || bad "no reply via python isolator ($(cat "$SD/d4.detach-output" 2>/dev/null))"

echo "== detach: instant child -> READY still observed, no false timeout =="
rm -rf "$SD"
run d5 --detach
[[ "$RC" -eq 0 ]] && grep -q '^DETACHED pid=' <<<"$OUT" && ok "fast child: DETACHED printed with exit 0" || bad "fast child rc=$RC out=$OUT err=$(cat "$T/err")"
grep -qi 'timed out' "$T/err" && bad "false timeout reported for a fast child" || ok "no false timeout (child never deletes READY)"
i=0; while ! grep -q FAKE_REPLY "$SD/d5.log" 2>/dev/null && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
grep -q FAKE_REPLY "$SD/d5.log" 2>/dev/null && ok "fast child: reply landed" || bad "fast child: no reply"

echo "== detach + concurrent cleanup: live lease shields an old-mtime thread =="
CLEANUP="$(dirname "$DRIVER")/cleanup.sh"
rm -rf "$SD"
FAKE_CODEX_SLEEP=3 run d6 --detach
[[ "$RC" -eq 0 ]] && grep -q '^DETACHED pid=' <<<"$OUT" && ok "detach parent returned for the race test" || bad "race-test detach rc=$RC out=$OUT err=$(cat "$T/err")"
# The child sleeps inside the stub having written NOTHING but its lease and the
# sidecar. Age every member so only lease liveness — not mtime — protects it.
touch -t 202001010000 "$SD"/d6.* 2>/dev/null
CLEANOUT="$(bash "$CLEANUP" --older-than 1 --apply 2>&1)"; CRC=$?
[[ "$CRC" -eq 0 ]] && grep -q 'IN USE  d6' <<<"$CLEANOUT" && ok "concurrent cleanup skipped the in-flight thread" || bad "cleanup race (rc=$CRC out=$CLEANOUT)"
[[ -f "$SD/d6.active" ]] && ok "lease untouched by concurrent cleanup" || bad "cleanup removed the live lease"
i=0; while ! grep -q FAKE_REPLY "$SD/d6.log" 2>/dev/null && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
grep -q FAKE_REPLY "$SD/d6.log" 2>/dev/null && ok "dispatch completed intact after concurrent cleanup" || bad "dispatch broken by concurrent cleanup ($(cat "$SD/d6.detach-output" 2>/dev/null))"
[[ "$(cat "$SD/d6.rounds" 2>/dev/null)" == "1" ]] && ok "rounds bumped exactly once despite the race" || bad "rounds after race: $(cat "$SD/d6.rounds" 2>/dev/null)"

echo "== detach: first-ever detach in a fresh repo (no state dir at all) =="
REPO2="$T/repo2"
mkdir -p "$REPO2" && cd "$REPO2"
git init -q -b main . && git config user.email t@t.t && git config user.name t
echo '.claude/codex-threads/' > .gitignore
echo y > g.txt && git add -A && git commit -qm init
run d7 --detach
[[ "$RC" -eq 0 ]] && grep -q '^DETACHED pid=' <<<"$OUT" && ok "first detach succeeds with no pre-existing state dir" || bad "fresh-repo detach rc=$RC out=$OUT err=$(cat "$T/err")"
i=0; while ! grep -q FAKE_REPLY "$SD/d7.log" 2>/dev/null && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
grep -q FAKE_REPLY "$SD/d7.log" 2>/dev/null && ok "thread log created + reply landed" || bad "no reply in the fresh repo"
[[ -f "$SD/d7.detach-output" ]] && ok "sidecar created" || bad "no sidecar in the fresh repo"
cd "$REPO"

echo "== detach: launcher killed mid-handshake leaves no tmpfiles =="
rm -rf "$SD"
mkdir -p "$T/dtmp8" "$T/slowisol"
# A setsid stub that never execs the child: READY is never written, so the
# launcher sits in its poll loop — exactly the window where a TERM must not
# leak the launcher-owned prompt/READY tmpfiles.
cat > "$T/slowisol/setsid" <<'S'
#!/usr/bin/env bash
sleep 15
S
chmod +x "$T/slowisol/setsid"
TMPDIR="$T/dtmp8" PATH="$T/slowisol:$PATH" bash "$DRIVER" d8 --detach <<< "ping" > "$T/d8.out" 2>&1 &
LPID=$!
i=0; while [[ -z "$(ls -A "$T/dtmp8" 2>/dev/null)" && $i -lt 50 ]]; do sleep 0.1; i=$((i+1)); done
[[ -n "$(ls -A "$T/dtmp8" 2>/dev/null)" ]] && ok "prompt/READY tmpfiles allocated during the handshake" || bad "no tmpfiles ever appeared"
kill -TERM "$LPID" 2>/dev/null
wait "$LPID" 2>/dev/null
i=0; while [[ -n "$(ls -A "$T/dtmp8" 2>/dev/null)" && $i -lt 20 ]]; do sleep 0.1; i=$((i+1)); done
[[ -z "$(ls -A "$T/dtmp8" 2>/dev/null)" ]] && ok "TERM mid-handshake left no tmpfiles" || bad "leftover tmpfiles: $(ls -A "$T/dtmp8")"

echo "== atomic lease: barrier-controlled two-driver race -> exactly one dispatch =="
cd "$REPO"
rm -rf "$SD"
mkdir -p "$T/racebin"
REAL_MKDIR="$(command -v mkdir)"
# A PATH mkdir stub that BARRIERS on the .active.lock claim: both drivers
# block until both have reached the mutex mkdir, then race it — the exact
# check-then-overwrite window the mutex must close.
cat > "$T/racebin/mkdir" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *.active.lock)
    echo x >> "$T/race.barrier"
    i=0
    while [ "\$(wc -l < "$T/race.barrier" | tr -d ' ')" -lt 2 ] && [ "\$i" -lt 100 ]; do sleep 0.05; i=\$((i+1)); done
  ;; esac
done
exec "$REAL_MKDIR" "\$@"
STUB
chmod +x "$T/racebin/mkdir"
rm -f "$T/race.barrier" "$T/race.calls"
PATH="$T/racebin:$PATH" FAKE_CODEX_SLEEP=2 FAKE_CODEX_CALLS="$T/race.calls" bash "$DRIVER" r1 <<< "ping" > "$T/r1a.out" 2>"$T/r1a.err" &
P1=$!
PATH="$T/racebin:$PATH" FAKE_CODEX_SLEEP=2 FAKE_CODEX_CALLS="$T/race.calls" bash "$DRIVER" r1 <<< "ping" > "$T/r1b.out" 2>"$T/r1b.err" &
P2=$!
wait "$P1"; RC1=$?
wait "$P2"; RC2=$?
CALLS="$(wc -l < "$T/race.calls" 2>/dev/null | tr -d ' ')"
[[ "$CALLS" == "1" ]] && ok "stub codex reached EXACTLY once" || bad "stub invocations: ${CALLS:-0}"
if [[ ( "$RC1" -eq 0 && "$RC2" -eq 10 ) || ( "$RC1" -eq 10 && "$RC2" -eq 0 ) ]]; then
  ok "one dispatch succeeded, the other refused with exit 10 (rc1=$RC1 rc2=$RC2)"
else
  bad "race exit codes: rc1=$RC1 rc2=$RC2 (err1: $(cat "$T/r1a.err"); err2: $(cat "$T/r1b.err"))"
fi
grep -q 'busy' "$T/r1a.err" "$T/r1b.err" && ok "loser explained the refusal" || bad "no busy message: $(cat "$T/r1a.err" "$T/r1b.err")"
[[ ! -e "$SD/r1.active" && ! -e "$SD/r1.active.lock" ]] && ok "lease + mutex both released after the race" || bad "leftover lease/lock: $(ls "$SD" 2>/dev/null)"

echo "== busy --new: refused BEFORE any state reset (sidecars byte-for-byte intact) =="
rm -rf "$SD"; mkdir -p "$SD"
printf '%s' "$UUID" > "$SD/n1.id"
echo "3" > "$SD/n1.rounds"
printf '{"finding":1}\n' > "$SD/n1.findings.jsonl"
printf 'scope-pin\n' > "$SD/n1.scope"
printf 'approved-sha\n' > "$SD/n1.approved"
mkdir -p "$T/n1snap"; cp "$SD"/n1.* "$T/n1snap/"
sleep 30 & NL=$!
printf '%s' "$NL" > "$SD/n1.active"
run n1 --new
[[ "$RC" -eq 10 ]] && ok "busy --new -> exit 10" || bad "busy --new rc=$RC err=$(cat "$T/err")"
same=true
for f in n1.id n1.rounds n1.findings.jsonl n1.scope n1.approved; do
  cmp -s "$SD/$f" "$T/n1snap/$f" || { same=false; bad "sidecar changed by the refused --new: $f"; }
done
$same && ok "every sidecar byte-for-byte unchanged"

echo "== busy + invalid saved ID: refused BEFORE the invalid-ID discard =="
printf 'not-a-uuid' > "$SD/n2.id"
printf '%s' "$NL" > "$SD/n2.active"
run n2
[[ "$RC" -eq 10 ]] && ok "busy thread with invalid .id -> exit 10" || bad "busy invalid-id rc=$RC err=$(cat "$T/err")"
[[ "$(cat "$SD/n2.id" 2>/dev/null)" == "not-a-uuid" ]] && ok "invalid .id NOT discarded while busy" || bad ".id touched: '$(cat "$SD/n2.id" 2>/dev/null)'"
run n2 --new
[[ "$RC" -eq 10 && "$(cat "$SD/n2.id" 2>/dev/null)" == "not-a-uuid" ]] && ok "busy --new + invalid .id: refused, .id intact" || bad "busy --new invalid-id rc=$RC id='$(cat "$SD/n2.id" 2>/dev/null)'"
kill "$NL" 2>/dev/null; wait "$NL" 2>/dev/null

echo "== stale acquisition mutex (crashed acquirer) is stolen, dispatch proceeds =="
rm -rf "$SD"; mkdir -p "$SD/s1.active.lock"
touch -t 202001010000 "$SD/s1.active.lock"
run s1
[[ "$RC" -eq 0 && "$OUT" == "FAKE_REPLY" ]] && ok "stale lock stolen, dispatch went through" || bad "stale-lock rc=$RC err=$(cat "$T/err")"
[[ ! -e "$SD/s1.active.lock" ]] && ok "stolen lock released after the dispatch" || bad "lock left behind"

echo "== FRESH foreign acquisition mutex refuses the dispatch (exit 10) =="
mkdir -p "$SD/s2.active.lock"
export FAKE_CODEX_ARGV="$T/s2argv"; rm -f "$T/s2argv"
run s2
[[ "$RC" -eq 10 ]] && ok "fresh foreign lock -> exit 10" || bad "fresh-lock rc=$RC err=$(cat "$T/err")"
grep -q 'concurrent lease acquisition' "$T/err" && ok "refusal names the lock contention" || bad "lock message: $(cat "$T/err")"
[[ ! -e "$T/s2argv" ]] && ok "stub codex never ran under the foreign lock" || bad "dispatch ran despite the lock"
[[ -d "$SD/s2.active.lock" ]] && ok "foreign lock left in place (not ours to release)" || bad "foreign lock removed"
unset FAKE_CODEX_ARGV
rm -rf "$SD/s2.active.lock"

echo "== live-owner acquisition mutex is NEVER stolen, regardless of age =="
rm -rf "$SD"; mkdir -p "$SD/o1.active.lock"
sleep 30 & LOCKOWNER=$!
printf '%s' "$LOCKOWNER" > "$SD/o1.active.lock/owner"
touch -t 202001010000 "$SD/o1.active.lock"   # old mtime must NOT permit the steal
export FAKE_CODEX_ARGV="$T/o1argv"; rm -f "$T/o1argv"
run o1
[[ "$RC" -eq 10 ]] && ok "old lock with LIVE owner -> exit 10" || bad "live-owner lock rc=$RC err=$(cat "$T/err")"
grep -q "pid=$LOCKOWNER" "$T/err" && ok "refusal names the live lock holder" || bad "holder not named: $(cat "$T/err")"
[[ -d "$SD/o1.active.lock" ]] && ok "live-owner lock left in place" || bad "live-owner lock stolen"
[[ "$(cat "$SD/o1.active.lock/owner" 2>/dev/null)" == "$LOCKOWNER" ]] && ok "owner token untouched" || bad "owner token altered: '$(cat "$SD/o1.active.lock/owner" 2>/dev/null)'"
[[ ! -e "$T/o1argv" ]] && ok "stub codex never ran under the live-owner lock" || bad "dispatch ran despite the live-owner lock"
kill "$LOCKOWNER" 2>/dev/null; wait "$LOCKOWNER" 2>/dev/null
unset FAKE_CODEX_ARGV
rm -rf "$SD/o1.active.lock"

echo "== dead-owner acquisition mutex is stolen even when FRESH -> one dispatch =="
sleep 0 & DOP=$!; wait "$DOP" 2>/dev/null
mkdir -p "$SD/o2.active.lock"
printf '%s' "$DOP" > "$SD/o2.active.lock/owner"   # fresh mtime: age must not matter
rm -f "$T/o2.calls"
FAKE_CODEX_CALLS="$T/o2.calls" run o2
[[ "$RC" -eq 0 && "$OUT" == "FAKE_REPLY" ]] && ok "dead-owner lock stolen, dispatch went through" || bad "dead-owner steal rc=$RC err=$(cat "$T/err")"
[[ "$(wc -l < "$T/o2.calls" 2>/dev/null | tr -d ' ')" == "1" ]] && ok "exactly one dispatch over the dead-owner lock" || bad "dispatch count: $(wc -l < "$T/o2.calls" 2>/dev/null | tr -d ' ')"
[[ ! -e "$SD/o2.active.lock" ]] && ok "reclaimed lock released after the dispatch" || bad "lock left behind"

echo "== robbed acquirer aborts before the lease write (no .active, robber's lock intact) =="
rm -rf "$SD"
mkdir -p "$T/robbin"
REAL_CAT="$(command -v cat)"
# A PATH cat stub that swaps the owner token to a foreign PID the first time
# the driver reads it back — simulating a stale-takeover robbing this acquirer
# between its mkdir + token write and its lease write.
cat > "$T/robbin/cat" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *.active.lock/owner)
    if [ ! -e "$T/robbed" ]; then
      printf '%s' 424242 > "\$a"
      : > "$T/robbed"
    fi
  ;; esac
done
exec "$REAL_CAT" "\$@"
STUB
chmod +x "$T/robbin/cat"
rm -f "$T/robbed"
export FAKE_CODEX_ARGV="$T/o3argv"; rm -f "$T/o3argv"
OUT="$(PATH="$T/robbin:$PATH" bash "$DRIVER" o3 2>"$T/err" <<< "ping")"; RC=$?
[[ "$RC" -eq 10 ]] && ok "robbed acquirer -> exit 10" || bad "robbed rc=$RC err=$(cat "$T/err")"
[[ ! -e "$SD/o3.active" ]] && ok "no lease written by the robbed acquirer" || bad ".active written despite the robbery"
[[ -d "$SD/o3.active.lock" && "$(cat "$SD/o3.active.lock/owner" 2>/dev/null)" == "424242" ]] && ok "robber's lock + owner token left intact" || bad "robber's lock touched: owner='$(cat "$SD/o3.active.lock/owner" 2>/dev/null)'"
[[ ! -e "$T/o3argv" ]] && ok "stub codex never ran for the robbed acquirer" || bad "dispatch ran despite losing the lock"
unset FAKE_CODEX_ARGV
rm -rf "$SD/o3.active.lock"

echo "== live acquirer paused BEFORE the token write cannot clobber a reclaimer's token =="
# The mkdir→owner-token window: A wins the mkdir but stalls before publishing
# its token; after 60s B legitimately reclaims the ownerless dir and writes
# ITS token. A's resumed token write must FAIL (noclobber) — an unguarded
# overwrite would hand both processes a verified claim (double dispatch).
rm -rf "$SD"
mkdir -p "$T/pausebin"
REAL_MKDIR2="$(command -v mkdir)"
# PATH mkdir stub for driver A: after WINNING the .active.lock mkdir it pauses
# (marker + flag-file wait) — exactly the pre-token stall under test.
cat > "$T/pausebin/mkdir" <<STUB
#!/usr/bin/env bash
"$REAL_MKDIR2" "\$@"; rc=\$?
for a in "\$@"; do
  case "\$a" in *.active.lock)
    if [ "\$rc" -eq 0 ]; then
      : > "$T/p1.a-won"
      i=0
      while [ ! -e "$T/p1.resume-a" ] && [ "\$i" -lt 300 ]; do sleep 0.05; i=\$((i+1)); done
    fi
  ;; esac
done
exit "\$rc"
STUB
chmod +x "$T/pausebin/mkdir"
mkdir -p "$T/verifybin"
REAL_CAT2="$(command -v cat)"
# PATH cat stub for driver B: the FIRST time it reads an EXISTING owner token
# (B's own re-verify, after B reclaimed the lock and wrote its token) it
# pauses — holding B inside its critical section while A resumes.
cat > "$T/verifybin/cat" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *.active.lock/owner)
    if [ -e "\$a" ] && [ ! -e "$T/p1.b-at-verify" ]; then
      : > "$T/p1.b-at-verify"
      i=0
      while [ ! -e "$T/p1.resume-b" ] && [ "\$i" -lt 300 ]; do sleep 0.05; i=\$((i+1)); done
    fi
  ;; esac
done
exec "$REAL_CAT2" "\$@"
STUB
chmod +x "$T/verifybin/cat"
rm -f "$T/p1.a-won" "$T/p1.resume-a" "$T/p1.b-at-verify" "$T/p1.resume-b" "$T/p1.calls"
PATH="$T/pausebin:$PATH" FAKE_CODEX_CALLS="$T/p1.calls" bash "$DRIVER" p1 <<< "ping" > "$T/p1a.out" 2>"$T/p1a.err" &
PA=$!
i=0; while [[ ! -e "$T/p1.a-won" && $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
[[ -e "$T/p1.a-won" ]] && ok "A won the mkdir and paused before the token write" || bad "A never reached the pause"
touch -t 202001010000 "$SD/p1.active.lock"   # age the ownerless lock past the 60s reclaim threshold
PATH="$T/verifybin:$PATH" FAKE_CODEX_CALLS="$T/p1.calls" bash "$DRIVER" p1 <<< "ping" > "$T/p1b.out" 2>"$T/p1b.err" &
PB=$!
i=0; while [[ ! -e "$T/p1.b-at-verify" && $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
[[ -e "$T/p1.b-at-verify" ]] && ok "B reclaimed the ownerless lock and holds its token" || bad "B never reached its re-verify"
[[ "$(cat "$SD/p1.active.lock/owner" 2>/dev/null)" == "$PB" ]] && ok "owner token names B" || bad "owner token: '$(cat "$SD/p1.active.lock/owner" 2>/dev/null)' expected $PB"
: > "$T/p1.resume-a"          # A resumes exactly at its owner-token write
wait "$PA"; RCA=$?
[[ "$RCA" -eq 10 ]] && ok "resumed pre-token loser A refused with exit 10" || bad "A rc=$RCA err=$(cat "$T/p1a.err")"
[[ "$(cat "$SD/p1.active.lock/owner" 2>/dev/null)" == "$PB" ]] && ok "B's token intact after A's refused write" || bad "B's token clobbered: '$(cat "$SD/p1.active.lock/owner" 2>/dev/null)'"
: > "$T/p1.resume-b"          # release B — it must dispatch normally
wait "$PB"; RCB=$?
[[ "$RCB" -eq 0 ]] && ok "reclaimer B dispatched successfully" || bad "B rc=$RCB err=$(cat "$T/p1b.err")"
P1CALLS="$(wc -l < "$T/p1.calls" 2>/dev/null | tr -d ' ')"
[[ "$P1CALLS" == "1" ]] && ok "exactly one dispatch total" || bad "dispatch count: ${P1CALLS:-0}"
[[ ! -e "$SD/p1.active" && ! -e "$SD/p1.active.lock" ]] && ok "lease + lock released after the pair" || bad "leftovers: $(ls "$SD" 2>/dev/null)"

echo "== detach: aborted handshake reaps a delayed READY-writing child =="
rm -rf "$SD"
mkdir -p "$T/dtmp9" "$T/delayisol"
# A fake isolator that IGNORES the real child and becomes a delayed sleeper:
# it records its PID, waits, then would recreate READY and keep living —
# unless the launcher's abort path actually terminates it.
cat > "$T/delayisol/setsid" <<S
#!/usr/bin/env bash
echo \$\$ > "$T/sleeper.pid"
sleep 2
printf '%s' "\$\$" > "\$CC_CODEX_READY_FILE"
sleep 30
S
chmod +x "$T/delayisol/setsid"
rm -f "$T/sleeper.pid"
TMPDIR="$T/dtmp9" PATH="$T/delayisol:$PATH" bash "$DRIVER" d9 --detach <<< "ping" > "$T/d9.out" 2>&1 &
LPID9=$!
i=0; while [[ ! -s "$T/sleeper.pid" && $i -lt 50 ]]; do sleep 0.1; i=$((i+1)); done
[[ -s "$T/sleeper.pid" ]] && ok "delayed child spawned and reported its PID" || bad "child never spawned"
kill -TERM "$LPID9" 2>/dev/null
wait "$LPID9" 2>/dev/null
SLEEPER="$(cat "$T/sleeper.pid" 2>/dev/null)"
i=0; while kill -0 "$SLEEPER" 2>/dev/null && [[ $i -lt 30 ]]; do sleep 0.1; i=$((i+1)); done
kill -0 "$SLEEPER" 2>/dev/null && bad "delayed child still alive after the launcher TERM" || ok "delayed child terminated by the abort path"
sleep 2.5   # ride past the child's READY-write moment — nothing may recreate it
[[ -z "$(ls -A "$T/dtmp9" 2>/dev/null)" ]] && ok "no READY resurrection, no leftover tmpfiles" || bad "leftovers: $(ls -A "$T/dtmp9")"

echo "== detach: handshake-timeout path also reaps a never-ready child =="
rm -rf "$SD"
mkdir -p "$T/dtmp10" "$T/noreadyisol"
# Never writes READY at all: the launcher must hit the 5s timeout, TERM the
# spawn, and CONFIRM it is gone before removing its tmpfiles.
cat > "$T/noreadyisol/setsid" <<S
#!/usr/bin/env bash
echo \$\$ > "$T/noready.pid"
sleep 60
S
chmod +x "$T/noreadyisol/setsid"
rm -f "$T/noready.pid"
TMPDIR="$T/dtmp10" PATH="$T/noreadyisol:$PATH" run d10 --detach
[[ "$RC" -eq 9 ]] && ok "never-ready child -> exit 9" || bad "timeout rc=$RC err=$(cat "$T/err")"
NRPID="$(cat "$T/noready.pid" 2>/dev/null)"
i=0; while kill -0 "$NRPID" 2>/dev/null && [[ $i -lt 30 ]]; do sleep 0.1; i=$((i+1)); done
kill -0 "$NRPID" 2>/dev/null && bad "never-ready child survived the timeout reap" || ok "never-ready child confirmed terminated"
[[ -z "$(ls -A "$T/dtmp10" 2>/dev/null)" ]] && ok "timeout path left no tmpfiles" || bad "leftovers: $(ls -A "$T/dtmp10")"

echo "== detach: child refusal (live foreign mutex) propagates exit 10, well under the 5s timeout =="
# The launcher's fast-fail pre-check covers only <thread>.active; a held
# ACQUISITION MUTEX is detected by the child AFTER the spawn — it exits 10
# without READY, and the parent must report THAT, not a 9-timeout.
rm -rf "$SD"; mkdir -p "$SD/e1.active.lock" "$T/dtmp11"
sleep 30 & E1OWNER=$!
printf '%s' "$E1OWNER" > "$SD/e1.active.lock/owner"
T0=$(date +%s)
TMPDIR="$T/dtmp11" run e1 --detach
T1=$(date +%s)
[[ "$RC" -eq 10 ]] && ok "detached dispatch against a live mutex -> exit 10" || bad "detach mutex rc=$RC err=$(cat "$T/err")"
[[ $((T1 - T0)) -lt 5 ]] && ok "refusal propagated early ($((T1 - T0))s < 5s timeout)" || bad "took $((T1 - T0))s — waited out the timeout"
grep -qi 'timed out' "$T/err" && bad "refusal misreported as a handshake timeout" || ok "no timeout misreport"
i=0; while [[ -n "$(ls -A "$T/dtmp11" 2>/dev/null)" && $i -lt 30 ]]; do sleep 0.1; i=$((i+1)); done
[[ -z "$(ls -A "$T/dtmp11" 2>/dev/null)" ]] && ok "early-exit path left no tmpfiles" || bad "leftovers: $(ls -A "$T/dtmp11")"
kill "$E1OWNER" 2>/dev/null; wait "$E1OWNER" 2>/dev/null
rm -rf "$SD/e1.active.lock"

echo "== detach: child refusal (non-regular .active) propagates exit 10 too =="
mkdir -p "$SD/e2.active"
T0=$(date +%s)
run e2 --detach
T1=$(date +%s)
[[ "$RC" -eq 10 ]] && ok "detached dispatch against a directory lease -> exit 10" || bad "detach dir-lease rc=$RC err=$(cat "$T/err")"
[[ $((T1 - T0)) -lt 5 ]] && ok "refusal propagated early ($((T1 - T0))s < 5s)" || bad "took $((T1 - T0))s"
rm -rf "$SD/e2.active"

echo "== detach: restricted ps (fails for EVERY pid) -> kill -0 trusted, no false 9/failure =="
# Regression: a ps that errors was read as "child dead" — in a
# process-restricted sandbox the launcher misreported healthy children.
# The broken-ps shim fails even for $$, so proc_state's self-probe must
# yield UNKNOWN and the launcher must trust kill -0 alone.
rm -rf "$SD"; mkdir -p "$SD" "$T/nops" "$T/dtmp12"
cat > "$T/nops/ps" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$T/nops/ps"
TMPDIR="$T/dtmp12" FAKE_CODEX_SLEEP=2 PATH="$T/nops:$PATH" run p1 --detach
[[ "$RC" -eq 0 ]] && grep -q '^DETACHED pid=' <<<"$OUT" && ok "broken ps: handshake still completes (kill -0 trusted)" || bad "broken-ps detach rc=$RC out=$OUT err=$(cat "$T/err")"
DP1="$(sed -n 's/^DETACHED pid=\([0-9]*\).*/\1/p' <<<"$OUT")"
i=0; while kill -0 "$DP1" 2>/dev/null && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
grep -q FAKE_REPLY "$SD/p1.log" 2>/dev/null && ok "reply landed despite broken ps" || bad "no reply with broken ps ($(cat "$SD/p1.detach-output" 2>/dev/null))"

echo "== detach sidecar: truncated per launch (no cross-run interleave) =="
run p2 --detach
DP2="$(sed -n 's/^DETACHED pid=\([0-9]*\).*/\1/p' <<<"$OUT")"
i=0; while kill -0 "$DP2" 2>/dev/null && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
printf 'STALE_MARKER\n' >> "$SD/p2.detach-output"
run p2 --detach
DP2B="$(sed -n 's/^DETACHED pid=\([0-9]*\).*/\1/p' <<<"$OUT")"
i=0; while kill -0 "$DP2B" 2>/dev/null && [[ $i -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
grep -q 'STALE_MARKER' "$SD/p2.detach-output" 2>/dev/null && bad "sidecar kept the previous run's output" || ok "sidecar holds the latest run only"

echo "== DETACHED line carries log-offset= for the watcher baseline =="
grep -q 'log-offset=[0-9]' <<<"$OUT" && ok "log-offset printed" || bad "no log-offset in: $OUT"

echo "== detach-watch: reply landed -> exit 0 and prints the log delta =="
WATCH="${DRIVER%codex-thread.sh}detach-watch.sh"   # suite cwd is inside the fixture repo — derive from DRIVER, not $0
OFF="$(sed -n 's/.*log-offset=\([0-9]*\).*/\1/p' <<<"$OUT")"
WOUT="$(bash "$WATCH" p2 "$DP2B" "$OFF" 2>&1)"; WRC=$?
[[ "$WRC" -eq 0 ]] && grep -q 'DONE' <<<"$WOUT" && grep -q 'FAKE_REPLY' <<<"$WOUT" && ok "watcher reports the landed reply" || bad "watcher success path rc=$WRC out=$WOUT"

echo "== detach-watch: worker died with NO new round -> exit 1 with diagnostics =="
rm -rf "$SD"; mkdir -p "$SD"
printf 'old\n' > "$SD/p3.log"
printf '{"err":"boom"}\n' > "$SD/p3.last-error.jsonl"
printf 'raw child noise\n' > "$SD/p3.detach-output"
BASE="$(wc -c < "$SD/p3.log" | tr -d ' ')"
sleep 0.2 & DEADW=$!; wait "$DEADW" 2>/dev/null
WOUT="$(bash "$WATCH" p3 "$DEADW" "$BASE" 2>&1)"; WRC=$?
[[ "$WRC" -eq 1 ]] && grep -q 'FAILED' <<<"$WOUT" && grep -q 'boom' <<<"$WOUT" && grep -q 'raw child noise' <<<"$WOUT" \
  && ok "watcher surfaces the post-READY failure diagnostics" || bad "watcher failure path rc=$WRC out=$WOUT"

echo "== detach-watch: outside a git repo -> exit 7 =="
WNG="$T/watchnongit"; mkdir -p "$WNG"
( cd "$WNG" && CLAUDE_PROJECT_DIR="$WNG" bash "$WATCH" x 1 ) >/dev/null 2>&1; WRC=$?
[[ "$WRC" -eq 7 ]] && ok "watcher outside a repo -> exit 7" || bad "watcher non-git rc=$WRC"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
