#!/usr/bin/env bash
export CC_CODEX_STATE_DIR=.claude/codex-threads
export CC_CODEX_GATE_DIR=.claude/codex-threads
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
set -u
LEDGER="$(cd "$(dirname "$0")/.." && pwd)/plugins/cc-codex-triage/scripts/ledger.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/tmp}/cc-ledger.XXXXXX")"; trap 'rm -rf "$T"' EXIT
# The ledger hard-fails outside a git repo (exit 7, driver parity) — the
# fixture must be a repo, exactly like every production caller.
export CLAUDE_PROJECT_DIR="$T"; cd "$T"; git init -q -b main .

( D="$(mktemp -d)"; cd "$D" && CLAUDE_PROJECT_DIR="$D" bash "$LEDGER" list x ) >/dev/null 2>&1; rc=$?
[[ "$rc" -eq 7 ]] && ok "outside a git repo -> exit 7 (hard root anchoring)" || bad "non-git ledger rc=$rc"

id="$(bash "$LEDGER" create th --file a.py --line 3 --severity blocking --title t --confidence 0.9)"
got="$(bash "$LEDGER" get th "$id" | jq -r '.confidence')"
[[ "$got" == "0.9" ]] && ok "confidence round-trips" || bad "confidence: $got"

id2="$(bash "$LEDGER" create th --file b.py --line 1 --severity non-blocking --title t2)"
got2="$(bash "$LEDGER" get th "$id2" | jq -r '.confidence')"
[[ "$got2" == "null" ]] && ok "confidence optional -> null" || bad "confidence not null: $got2"

id3="$(bash "$LEDGER" create th --file c.py --line 2 --severity blocking --title t3 --confidence 5)"
got3="$(bash "$LEDGER" get th "$id3" | jq -r '.confidence')"
[[ "$got3" == "null" ]] && ok "out-of-range confidence -> null" || bad "out-of-range confidence not null: $got3"

id4="$(bash "$LEDGER" create th --file d.py --line 4 --severity blocking --title t4 --confidence abc)"
got4="$(bash "$LEDGER" get th "$id4" | jq -r '.confidence')"
[[ "$got4" == "null" ]] && ok "garbage confidence -> null" || bad "garbage confidence not null: $got4"

mkdir -p .claude/codex-threads
printf '{"event":"create","id":"f1","ts":"2024-01-01T00:00:00Z","file":"legacy.py","line":10,"severity":"blocking","label":"issue","title":"pre-0.7 record","status":"open"}\n' > .claude/codex-threads/legacy.findings.jsonl
getout="$(bash "$LEDGER" get legacy f1)"; getrc=$?
[[ "$getrc" -eq 0 ]] && ok "get reads pre-0.7 record (no confidence field) without error" || bad "get failed on pre-0.7 record (rc=$getrc)"
gotconf="$(jq -r '.confidence' <<<"$getout")"
[[ "$gotconf" == "null" ]] && ok "pre-0.7 record confidence -> null" || bad "pre-0.7 record confidence: $gotconf"
bash "$LEDGER" list legacy >/dev/null; listrc=$?
[[ "$listrc" -eq 0 ]] && ok "list reads pre-0.7 record without error" || bad "list failed on pre-0.7 record (rc=$listrc)"
bash "$LEDGER" open legacy >/dev/null; openrc=$?
[[ "$openrc" -eq 0 ]] && ok "open reads pre-0.7 record without error" || bad "open failed on pre-0.7 record (rc=$openrc)"

summary
