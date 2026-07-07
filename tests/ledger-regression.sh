#!/usr/bin/env bash
set -u
LEDGER="$(cd "$(dirname "$0")/.." && pwd)/plugins/cc-codex-triage/scripts/ledger.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/tmp}/cc-ledger.XXXXXX")"; trap 'rm -rf "$T"' EXIT
export CLAUDE_PROJECT_DIR="$T"; cd "$T"; PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok: $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

id="$(bash "$LEDGER" create th --file a.py --line 3 --severity blocking --title t --confidence 0.9)"
got="$(bash "$LEDGER" get th "$id" | jq -r '.confidence')"
[[ "$got" == "0.9" ]] && ok "confidence round-trips" || bad "confidence: $got"

id2="$(bash "$LEDGER" create th --file b.py --line 1 --severity non-blocking --title t2)"
got2="$(bash "$LEDGER" get th "$id2" | jq -r '.confidence')"
[[ "$got2" == "null" ]] && ok "confidence optional -> null" || bad "confidence not null: $got2"

echo "PASS=$PASS FAIL=$FAIL"; [[ "$FAIL" -eq 0 ]]
