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
out=""
prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"
done
# record argv so tests can assert the driver forwarded flags to codex
printf '%s\0' "$@" > "${FAKE_CODEX_ARGV:-/dev/null}"
cat >/dev/null
if [[ "${FAKE_CODEX_SPACED:-0}" == "1" ]]; then
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

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
