#!/usr/bin/env bash
# Regression suite for scripts/cleanup.sh — synthetic state fixtures, no Codex.
# Usage: bash tests/cleanup-regression.sh   (exit 0 = all pass)
set -u

CLEANUP="$(cd "$(dirname "$0")/.." && pwd)/plugins/cc-codex-triage/scripts/cleanup.sh"
[[ -f "$CLEANUP" ]] || { echo "cleanup script not found: $CLEANUP"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cc-cleanup-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

REPO="$T/repo"
mkdir -p "$REPO" && cd "$REPO"
git init -q -b main . && git config user.email t@t.t && git config user.name t
echo '.claude/codex-threads/' > .gitignore
echo x > f.txt && git add -A && git commit -qm init
unset CLAUDE_PROJECT_DIR 2>/dev/null || true

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
SD=.claude/codex-threads

OUT=""; RC=0
run() { OUT="$(bash "$CLEANUP" "$@" 2>&1)"; RC=$?; }
reset_state() { rm -rf "$SD"; mkdir -p "$SD"; }
old() { touch -t 202001010000 "$@"; }        # well past any --older-than window
# Newest .archive-* subdir created by the last --apply.
last_archive() { ls -td "$SD"/.archive-* 2>/dev/null | head -1; }

echo "== --older-than validation: 0 / negative / non-numeric / missing rejected =="
reset_state
run --older-than 0
[[ "$RC" -ne 0 ]] && grep -q '>= 1' <<<"$OUT" && ok "--older-than 0 rejected" || bad "--older-than 0 (rc=$RC out=$OUT)"
run --older-than -3
[[ "$RC" -ne 0 ]] && ok "--older-than -3 rejected" || bad "--older-than -3 (rc=$RC)"
run --older-than abc
[[ "$RC" -ne 0 ]] && ok "--older-than abc rejected" || bad "--older-than abc (rc=$RC)"
run --older-than
[[ "$RC" -ne 0 ]] && ok "--older-than without a value rejected" || bad "bare --older-than (rc=$RC)"
run --older-than 1
[[ "$RC" -eq 0 ]] && ok "--older-than 1 accepted" || bad "--older-than 1 (rc=$RC out=$OUT)"

echo "== orphan diag (no .id) flagged and archivable =="
reset_state
printf 'boom\n' > "$SD/x1.last-error.jsonl"
run
[[ "$RC" -eq 0 ]] && grep -q 'STALE-DIAG  x1' <<<"$OUT" && ok "orphan diag flagged on dry run" || bad "orphan diag not flagged (rc=$RC out=$OUT)"
[[ -f "$SD/x1.last-error.jsonl" ]] && ok "dry run did not move the diag" || bad "dry run moved the diag"
run --apply
[[ "$RC" -eq 0 && ! -e "$SD/x1.last-error.jsonl" && -f "$(last_archive)/x1.last-error.jsonl" ]] \
  && ok "--apply archived the orphan diag" || bad "orphan diag not archived (rc=$RC out=$OUT)"

echo "== recovered diag (.log newer than the diag) flagged =="
reset_state
echo u > "$SD/x2.id"
printf 'boom\n' > "$SD/x2.last-error.jsonl"; old "$SD/x2.last-error.jsonl"
echo l > "$SD/x2.log"
run
grep -q 'STALE-DIAG  x2' <<<"$OUT" && grep -q 'recovered' <<<"$OUT" && ok "recovered diag flagged" || bad "recovered diag not flagged: $OUT"
run --apply
[[ ! -e "$SD/x2.last-error.jsonl" && -f "$SD/x2.id" && -f "$SD/x2.log" ]] \
  && ok "--apply archived ONLY the diag, thread intact" || bad "recovered-diag apply wrong (out=$OUT)"

echo "== fresh diag (newer than the log, thread has .id) NOT flagged =="
reset_state
echo u > "$SD/x3.id"
echo l > "$SD/x3.log"; old "$SD/x3.log"
printf 'boom\n' > "$SD/x3.last-error.jsonl"
run
grep -q 'STALE-DIAG' <<<"$OUT" && bad "fresh diag wrongly flagged: $OUT" || ok "fresh diag not flagged"
grep -q 'Nothing to archive' <<<"$OUT" && ok "nothing queued for a fresh diag" || bad "something queued: $OUT"

echo "== dormant: old thread caught, fresh thread skipped =="
reset_state
echo u > "$SD/old1.id"; echo l > "$SD/old1.log"; old "$SD/old1.id" "$SD/old1.log"
echo u > "$SD/fr1.id";  echo l > "$SD/fr1.log"
run --older-than 30
grep -q 'DORMANT old1' <<<"$OUT" && ok "old thread listed as dormant" || bad "old thread not listed: $OUT"
grep -q 'DORMANT fr1' <<<"$OUT" && bad "fresh thread wrongly dormant" || ok "fresh thread not listed"
[[ -f "$SD/old1.id" ]] && ok "dry run moved nothing" || bad "dry run moved files"
run --older-than 30 --apply
[[ ! -e "$SD/old1.id" && ! -e "$SD/old1.log" ]] && ok "--apply moved the dormant set" || bad "dormant set not moved: $OUT"
a="$(last_archive)"
[[ -f "$a/old1.id" && -f "$a/old1.log" ]] && ok "dormant set present in the archive" || bad "dormant set missing from archive"
[[ -f "$SD/fr1.id" && -f "$SD/fr1.log" ]] && ok "fresh thread untouched" || bad "fresh thread moved"

echo "== dormant: armed-target thread skipped even when old =="
reset_state
echo u > "$SD/at1.id"; echo l > "$SD/at1.log"; old "$SD/at1.id" "$SD/at1.log"
BR="$(git rev-parse --abbrev-ref HEAD)"
printf 'branch=%s\nthread=at1\nlens=correctness\ncap=3\nblocks=0\nlog_bytes_at_arming=0\narmed_at=%s\n' \
  "$BR" "$(date +%s)" > "$SD/autoreview.armed"
run --older-than 30 --apply
grep -q 'SKIP    at1' <<<"$OUT" && ok "armed target reported as skipped" || bad "no skip note for armed target: $OUT"
[[ -f "$SD/at1.id" && -f "$SD/at1.log" ]] && ok "armed target not archived" || bad "armed target was archived"
rm -f "$SD/autoreview.armed"

echo "== in-flight race: live lease on an old-mtime thread is skipped by --apply =="
reset_state
echo u > "$SD/rl1.id"; echo l > "$SD/rl1.log"
sleep 30 & LIVE=$!
printf '%s' "$LIVE" > "$SD/rl1.active"
old "$SD/rl1.id" "$SD/rl1.log" "$SD/rl1.active"   # even the lease looks old — only liveness protects it
run --older-than 1 --apply
grep -q 'IN USE  rl1' <<<"$OUT" && ok "live lease reported IN USE" || bad "no IN USE note: $OUT"
[[ -f "$SD/rl1.id" && -f "$SD/rl1.log" && -f "$SD/rl1.active" ]] && ok "in-flight thread untouched" || bad "in-flight thread was archived"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null

echo "== dead-PID lease: thread archivable INCLUDING the lease file =="
reset_state
echo u > "$SD/dl1.id"; echo l > "$SD/dl1.log"
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null
printf '%s' "$DEAD" > "$SD/dl1.active"
old "$SD/dl1.id" "$SD/dl1.log" "$SD/dl1.active"
run --older-than 1 --apply
[[ ! -e "$SD/dl1.id" && ! -e "$SD/dl1.log" && ! -e "$SD/dl1.active" ]] \
  && ok "dead-PID lease: whole set moved" || bad "dead-lease set not moved: $OUT"
a="$(last_archive)"
[[ -f "$a/dl1.active" ]] && ok "lease file itself archived with the set" || bad "lease file not in archive"

echo "== malformed lease treated as stale (joins the set) =="
reset_state
echo u > "$SD/ml1.id"; printf 'not-a-pid' > "$SD/ml1.active"
old "$SD/ml1.id" "$SD/ml1.active"
run --older-than 1 --apply
[[ ! -e "$SD/ml1.id" && ! -e "$SD/ml1.active" ]] && ok "malformed lease archived with the set" || bad "malformed-lease set not moved: $OUT"

echo "== file-set includes log.1 + detach-output; --apply moves exactly the listed files =="
reset_state
for ext in id log log.1 rounds findings.jsonl scope approved detach-output; do
  echo z > "$SD/fu1.$ext"
done
touch -t 202001010001 "$SD/fu1.last-error.jsonl"   # diag NEWER than the log (fresh rule) but still ancient
old "$SD"/fu1.id "$SD"/fu1.log "$SD"/fu1.log.1 "$SD"/fu1.rounds "$SD"/fu1.findings.jsonl "$SD"/fu1.scope "$SD"/fu1.approved "$SD"/fu1.detach-output
run --older-than 30
grep -q 'DORMANT fu1' <<<"$OUT" && grep -q 'fu1.log.1' <<<"$OUT" && grep -q 'fu1.detach-output' <<<"$OUT" \
  && ok "dry run lists log.1 + detach-output in the set" || bad "set listing wrong: $OUT"
grep -q 'STALE-DIAG' <<<"$OUT" && bad "diag newer than log wrongly flagged stale" || ok "ancient-but-fresh diag left to the dormant set"
run --older-than 30 --apply
a="$(last_archive)"
allmoved=true
for ext in id log log.1 rounds findings.jsonl scope approved last-error.jsonl detach-output; do
  [[ ! -e "$SD/fu1.$ext" && -f "$a/fu1.$ext" ]] || { allmoved=false; bad "member not moved cleanly: fu1.$ext"; }
done
$allmoved && ok "all 9 members moved (src absent + dst present)"
leftovers="$(ls "$SD" 2>/dev/null)"
[[ -z "$leftovers" ]] && ok "nothing else left behind" || bad "unexpected leftovers: $leftovers"

echo "== rail 3: member touched between detection and --apply -> thread skipped =="
reset_state
echo u > "$SD/tb1.id"; echo l > "$SD/tb1.log"; old "$SD/tb1.id" "$SD/tb1.log"
# Wrapper-simulated race: cleanup's --apply calls mktemp exactly once (archive
# dir) AFTER detection and BEFORE any move — a PATH stub touches a member at
# that instant, so the re-stat rail must catch it.
REAL_MKTEMP="$(command -v mktemp)"
mkdir -p "$T/stub"
cat > "$T/stub/mktemp" <<STUB
#!/usr/bin/env bash
touch "$REPO/$SD/tb1.log"
exec "$REAL_MKTEMP" "\$@"
STUB
chmod +x "$T/stub/mktemp"
OUT="$(PATH="$T/stub:$PATH" bash "$CLEANUP" --older-than 30 --apply 2>&1)"; RC=$?
grep -q 'changed since detection' <<<"$OUT" && ok "re-stat rail reported the skip" || bad "no re-stat skip note: $OUT"
[[ -f "$SD/tb1.id" && -f "$SD/tb1.log" ]] && ok "touched thread left in place" || bad "touched thread was archived"

echo "== generic review/plan stay list-only even under --older-than =="
reset_state
echo u > "$SD/review.id"; echo l > "$SD/review.log"; old "$SD/review.id" "$SD/review.log"
run --older-than 30 --apply
grep -q 'DORMANT review' <<<"$OUT" && grep -q 'listed only' <<<"$OUT" && ok "generic dormant thread listed with the list-only note" || bad "generic note wrong: $OUT"
[[ -f "$SD/review.id" && -f "$SD/review.log" ]] && ok "generic thread not archived" || bad "generic thread was archived"

echo "== live lease also shields the orphan-log scan (in-flight initial dispatch) =="
reset_state
echo l > "$SD/oi1.log"                     # .log, no .id — looks orphaned...
sleep 30 & LIVE2=$!
printf '%s' "$LIVE2" > "$SD/oi1.active"    # ...but a dispatch is in flight
run --apply
grep -q 'IN USE  oi1' <<<"$OUT" && ok "in-flight orphan-looking thread reported IN USE" || bad "no IN USE for orphan scan: $OUT"
[[ -f "$SD/oi1.log" && -f "$SD/oi1.active" ]] && ok "in-flight orphan-looking thread untouched" || bad "orphan scan archived an in-flight thread"
kill "$LIVE2" 2>/dev/null; wait "$LIVE2" 2>/dev/null

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
