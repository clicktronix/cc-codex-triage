#!/usr/bin/env bash
# Regression suite for scripts/cleanup.sh — synthetic state fixtures, no Codex.
# Usage: bash tests/cleanup-regression.sh   (exit 0 = all pass)
set -u
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

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

echo "== --older-than: leading zero read base-10, overflow-length rejected =="
run --older-than 08
[[ "$RC" -eq 0 ]] && grep -q 'older than 8 day' <<<"$OUT" && ok "--older-than 08 handled as 8 (documented base-10 normalization)" || bad "--older-than 08 (rc=$RC out=$OUT)"
run --older-than 999999999999999
[[ "$RC" -ne 0 ]] && grep -q 'capped at 5 digits' <<<"$OUT" && ok "--older-than 999999999999999 rejected" || bad "huge --older-than (rc=$RC out=$OUT)"
run --older-than 30
[[ "$RC" -eq 0 ]] && ok "--older-than 30 accepted" || bad "--older-than 30 (rc=$RC out=$OUT)"

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

echo "== boundary spellings of a LIVE pid are still malformed (driver grammar, raw content) =="
# The driver writes the bare PID via printf '%s' "$$" — a leading zero, leading
# whitespace, or an embedded newline/additional line are spellings it never
# produces. Each must read as stale (archivable), NOT as IN USE, even while the
# embedded PID lives. (A TRAILING newline is stripped by $(cat) identically in
# driver and cleanup — that spelling is live-parity, not malformed.)
sleep 300 & LIVEPID=$!
reset_state
echo u > "$SD/mz1.id"; printf '0%s' "$LIVEPID"  > "$SD/mz1.active"   # leading zero
echo u > "$SD/mz2.id"; printf ' %s' "$LIVEPID"  > "$SD/mz2.active"   # leading space
echo u > "$SD/mz3.id"; printf '%s\n7' "$LIVEPID" > "$SD/mz3.active"  # embedded newline (a TRAILING one is stripped identically by $(cat) in driver and cleanup — that spelling is live-parity, not malformed)
old "$SD/mz1.id" "$SD/mz1.active" "$SD/mz2.id" "$SD/mz2.active" "$SD/mz3.id" "$SD/mz3.active"
run --older-than 1 --apply
for t in mz1 mz2 mz3; do
  [[ ! -e "$SD/$t.id" && ! -e "$SD/$t.active" ]] \
    && ok "$t: boundary-spelling lease archived (not IN USE)" \
    || bad "$t: boundary-spelling lease wrongly treated as live: $OUT"
done
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null || true

echo "== file-set includes log.1 + detach-output; --apply moves exactly the listed files =="
reset_state
for ext in id log log.1 rounds findings.jsonl scope approved detach-output detach-stderr detach-status; do
  echo z > "$SD/fu1.$ext"
done
touch -t 202001010001 "$SD/fu1.last-error.jsonl"   # diag NEWER than the log (fresh rule) but still ancient
old "$SD"/fu1.id "$SD"/fu1.log "$SD"/fu1.log.1 "$SD"/fu1.rounds "$SD"/fu1.findings.jsonl "$SD"/fu1.scope "$SD"/fu1.approved "$SD"/fu1.detach-output "$SD"/fu1.detach-stderr "$SD"/fu1.detach-status
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

echo "== rails matrix: armed target shields EVERY class =="
BR="$(git rev-parse --abbrev-ref HEAD)"
arm() { printf 'branch=%s\nthread=%s\nlens=correctness\ncap=3\nblocks=0\nlog_bytes_at_arming=0\narmed_at=%s\n' "$BR" "$1" "$(date +%s)" > "$SD/autoreview.armed"; }
reset_state; arm ao1; echo l > "$SD/ao1.log"                        # orphan-log class
run --apply
grep -q 'SKIP    ao1' <<<"$OUT" && [[ -f "$SD/ao1.log" ]] && ok "orphan-log class skips an armed target" || bad "orphan-log armed rail: $OUT"
reset_state; arm as1; echo s > "$SD/as1.scope"                      # sidecar-only class
run --apply
grep -q 'SKIP    as1' <<<"$OUT" && [[ -f "$SD/as1.scope" ]] && ok "sidecar class skips an armed target" || bad "sidecar armed rail: $OUT"
reset_state; arm ad1; printf 'boom\n' > "$SD/ad1.last-error.jsonl"  # stale-diag class
run --apply
grep -q 'SKIP    ad1' <<<"$OUT" && [[ -f "$SD/ad1.last-error.jsonl" ]] && ok "stale-diag class skips an armed target" || bad "stale-diag armed rail: $OUT"
# dormant class: covered by the at1 case above

echo "== rails matrix: generic review/plan are list-only in EVERY class =="
reset_state; echo l > "$SD/review.log"                              # orphan-log class
run --apply
grep -q 'GENERIC review' <<<"$OUT" && [[ -f "$SD/review.log" ]] && ok "orphan-log class lists a generic thread only" || bad "orphan-log generic rail: $OUT"
reset_state; echo s > "$SD/plan.scope"                              # sidecar-only class
run --apply
grep -q 'GENERIC plan' <<<"$OUT" && [[ -f "$SD/plan.scope" ]] && ok "sidecar class lists a generic thread only" || bad "sidecar generic rail: $OUT"
reset_state; printf 'boom\n' > "$SD/review.last-error.jsonl"        # stale-diag class
run --apply
grep -q 'GENERIC review' <<<"$OUT" && [[ -f "$SD/review.last-error.jsonl" ]] && ok "stale-diag class lists a generic thread only" || bad "stale-diag generic rail: $OUT"
# dormant class: covered by the generic list-only case above

echo "== rails matrix: dead lease joins the archivable set in EVERY class =="
sleep 0 & DEAD2=$!; wait "$DEAD2" 2>/dev/null
reset_state; echo l > "$SD/og1.log"; printf '%s' "$DEAD2" > "$SD/og1.active"                        # orphan-log class
run --apply
[[ ! -e "$SD/og1.log" && ! -e "$SD/og1.active" ]] && ok "orphan-log class archives the dead lease too" || bad "orphan-log dead lease: $OUT"
reset_state; echo s > "$SD/os1.scope"; printf '%s' "$DEAD2" > "$SD/os1.active"                      # sidecar-only class
run --apply
[[ ! -e "$SD/os1.scope" && ! -e "$SD/os1.active" ]] && ok "sidecar class archives the dead lease too" || bad "sidecar dead lease: $OUT"
reset_state; printf 'boom\n' > "$SD/ds1.last-error.jsonl"; printf '%s' "$DEAD2" > "$SD/ds1.active"  # stale-diag class
run --apply
[[ ! -e "$SD/ds1.last-error.jsonl" && ! -e "$SD/ds1.active" ]] && ok "stale-diag class archives the dead lease too" || bad "stale-diag dead lease: $OUT"
# dormant class: covered by the dl1 case above

echo "== apply-time revalidation: gate re-armed between detect and apply -> not moved =="
reset_state
printf 'branch=some-other-branch\nthread=x\nlens=correctness\ncap=3\nblocks=0\nlog_bytes_at_arming=0\n' > "$SD/autoreview.armed"
old "$SD/autoreview.armed"
REAL_MKTEMP="${REAL_MKTEMP:-$(command -v mktemp)}"
mkdir -p "$T/stub2"
cat > "$T/stub2/mktemp" <<STUB
#!/usr/bin/env bash
touch "$REPO/$SD/autoreview.armed"
exec "$REAL_MKTEMP" "\$@"
STUB
chmod +x "$T/stub2/mktemp"
OUT="$(PATH="$T/stub2:$PATH" bash "$CLEANUP" --apply 2>&1)"; RC=$?
grep -q 'changed since detection' <<<"$OUT" && ok "re-armed gate skip noted" || bad "no re-armed skip note: $OUT"
[[ -f "$SD/autoreview.armed" ]] && ok "re-armed gate not moved" || bad "re-armed gate was archived"
rm -f "$SD/autoreview.armed"

echo "== apply-time revalidation: diag refreshed between detect and apply -> not moved =="
reset_state
printf 'boom\n' > "$SD/dr1.last-error.jsonl"; old "$SD/dr1.last-error.jsonl"
mkdir -p "$T/stub3"
cat > "$T/stub3/mktemp" <<STUB
#!/usr/bin/env bash
touch "$REPO/$SD/dr1.last-error.jsonl"
exec "$REAL_MKTEMP" "\$@"
STUB
chmod +x "$T/stub3/mktemp"
OUT="$(PATH="$T/stub3:$PATH" bash "$CLEANUP" --apply 2>&1)"; RC=$?
grep -q 'changed since detection' <<<"$OUT" && ok "refreshed diag skip noted" || bad "no refreshed-diag skip note: $OUT"
[[ -f "$SD/dr1.last-error.jsonl" ]] && ok "refreshed diag not moved" || bad "refreshed diag was archived"

echo "== apply-time revalidation: thread armed between detect and apply -> not moved =="
reset_state
printf 'boom\n' > "$SD/ar2.last-error.jsonl"; old "$SD/ar2.last-error.jsonl"
mkdir -p "$T/stub4"
cat > "$T/stub4/mktemp" <<STUB
#!/usr/bin/env bash
printf 'branch=main\nthread=ar2\nlens=correctness\ncap=3\nblocks=0\nlog_bytes_at_arming=0\n' > "$REPO/$SD/autoreview.armed"
exec "$REAL_MKTEMP" "\$@"
STUB
chmod +x "$T/stub4/mktemp"
OUT="$(PATH="$T/stub4:$PATH" bash "$CLEANUP" --apply 2>&1)"; RC=$?
grep -q 'SKIP (armed since detection): thread ar2' <<<"$OUT" && ok "armed-since-detection rail re-check noted" || bad "no armed-since-detection note: $OUT"
[[ -f "$SD/ar2.last-error.jsonl" ]] && ok "newly-armed target's diag not moved" || bad "newly-armed diag was archived"
rm -f "$SD/autoreview.armed"

echo "== per-thread apply unit: overlapping flat target + dormant set moves as ONE unit =="
reset_state
printf 'scope-pin\n' > "$SD/ov1.scope"       # sidecar-only orphan -> ALSO a flat target
echo 1 > "$SD/ov1.rounds"                    # dormant-only member
old "$SD/ov1.rounds"
touch -t 202001020000 "$SD/ov1.scope"        # strictly newest member of the set
run --older-than 30 --apply
grep -q 'changed since detection' <<<"$OUT" && bad "self-triggered changed-since-detection: $OUT" || ok "no self-trigger from the flat member"
[[ ! -e "$SD/ov1.scope" && ! -e "$SD/ov1.rounds" ]] && ok "whole set archived, nothing left behind" || bad "half-done set: $(ls "$SD" 2>/dev/null)"
a="$(last_archive)"
[[ -f "$a/ov1.scope" && -f "$a/ov1.rounds" ]] && ok "both members landed in the archive" || bad "archive incomplete: $(ls "$a" 2>/dev/null)"
grep -q 'Archived 2/2' <<<"$OUT" && ok "each file moved exactly once (2/2)" || bad "count wrong: $(grep Archived <<<"$OUT")"

echo "== per-thread apply unit: lease created between detection and apply -> unit skipped =="
reset_state
echo u > "$SD/lv1.id"; echo l > "$SD/lv1.log"; old "$SD/lv1.id" "$SD/lv1.log"
sleep 30 & LIVE4=$!
REAL_MKTEMP="${REAL_MKTEMP:-$(command -v mktemp)}"
mkdir -p "$T/stub5"
cat > "$T/stub5/mktemp" <<STUB
#!/usr/bin/env bash
printf '%s' "$LIVE4" > "$REPO/$SD/lv1.active"
exec "$REAL_MKTEMP" "\$@"
STUB
chmod +x "$T/stub5/mktemp"
OUT="$(PATH="$T/stub5:$PATH" bash "$CLEANUP" --older-than 30 --apply 2>&1)"; RC=$?
grep -q 'SKIP (in use since detection): thread lv1' <<<"$OUT" && ok "lease-since-detection skip noted" || bad "no in-use skip note: $OUT"
[[ -f "$SD/lv1.id" && -f "$SD/lv1.log" ]] && ok "unit left untouched under the fresh lease" || bad "unit was archived"
kill "$LIVE4" 2>/dev/null; wait "$LIVE4" 2>/dev/null
rm -f "$SD/lv1.active"

echo "== per-thread apply unit: gate armed while an EARLIER unit moved -> later unit skipped =="
reset_state
printf 'boom\n' > "$SD/aa1.last-error.jsonl"; old "$SD/aa1.last-error.jsonl"   # earlier unit (sorts first)
echo u > "$SD/ov3.id"; echo l > "$SD/ov3.log"; old "$SD/ov3.id" "$SD/ov3.log"  # later dormant unit
REAL_MV="$(command -v mv)"
mkdir -p "$T/stub6"
# The FIRST move of the apply arms a gate targeting ov3 — with no cross-unit
# rail caching, ov3's unit (checked later, adjacent to its own move) must see it.
cat > "$T/stub6/mv" <<STUB
#!/usr/bin/env bash
if [ ! -f "$REPO/$SD/autoreview.armed" ]; then
  printf 'branch=main\nthread=ov3\nlens=correctness\ncap=3\nblocks=0\nlog_bytes_at_arming=0\n' > "$REPO/$SD/autoreview.armed"
fi
exec "$REAL_MV" "\$@"
STUB
chmod +x "$T/stub6/mv"
OUT="$(PATH="$T/stub6:$PATH" bash "$CLEANUP" --older-than 30 --apply 2>&1)"; RC=$?
grep -q 'SKIP (armed since detection): thread ov3' <<<"$OUT" && ok "gate armed mid-apply blocks the later unit" || bad "no armed-since-detection note: $OUT"
[[ -f "$SD/ov3.id" && -f "$SD/ov3.log" ]] && ok "later unit untouched despite passing detection" || bad "later unit archived under a fresh gate"
[[ ! -e "$SD/aa1.last-error.jsonl" ]] && ok "earlier unit still archived normally" || bad "earlier unit not archived: $OUT"
rm -f "$SD/autoreview.armed"

echo "== apply mutex: lease injected AFTER lock acquisition -> under-lock re-check skips the unit =="
# The TOCTOU this closes: without the mutex, a dispatch could write a lease
# between the rail check and the mv. The test seam injects a live lease at
# the last point a legitimate writer could (post-lock, pre-re-check) — the
# unit must be skipped, not archived.
reset_state
echo u > "$SD/tc1.id"; echo l > "$SD/tc1.log"; old "$SD/tc1.id" "$SD/tc1.log"
sleep 30 & LIVE5=$!
cat > "$T/postlock.sh" <<HOOK
printf '%s' "$LIVE5" > "$SD/tc1.active"
HOOK
OUT="$(CC_CLEANUP_TEST_POST_LOCK_HOOK="$T/postlock.sh" bash "$CLEANUP" --older-than 30 --apply 2>&1)"; RC=$?
grep -q 'SKIP (in use since detection): thread tc1' <<<"$OUT" && ok "post-lock lease caught by the under-lock re-check" || bad "post-lock lease not caught: $OUT"
[[ -f "$SD/tc1.id" && -f "$SD/tc1.log" ]] && ok "unit untouched" || bad "unit archived despite live lease"
[[ ! -d "$SD/tc1.active.lock" ]] && ok "mutex released after the skip" || bad "mutex leaked"
kill "$LIVE5" 2>/dev/null; wait "$LIVE5" 2>/dev/null
rm -f "$SD/tc1.active"

echo "== apply mutex: acquisition lock held by a LIVE owner -> unit treated as busy, lock not stolen =="
reset_state
echo u > "$SD/tc2.id"; echo l > "$SD/tc2.log"; old "$SD/tc2.id" "$SD/tc2.log"
sleep 30 & LIVE6=$!
mkdir -p "$SD/tc2.active.lock"
printf '%s' "$LIVE6" > "$SD/tc2.active.lock/owner"
OUT="$(bash "$CLEANUP" --older-than 30 --apply 2>&1)"; RC=$?
grep -q 'SKIP (in use since detection): thread tc2' <<<"$OUT" && ok "live-owner lock skips the unit" || bad "live-owner lock not respected: $OUT"
[[ -f "$SD/tc2.id" && "$(cat "$SD/tc2.active.lock/owner" 2>/dev/null)" == "$LIVE6" ]] && ok "unit and foreign lock left intact" || bad "unit archived or lock stolen"
kill "$LIVE6" 2>/dev/null; wait "$LIVE6" 2>/dev/null
rm -rf "$SD/tc2.active.lock"

echo "== apply mutex: DEAD-owner lock reclaimed, unit archives, lock released =="
reset_state
echo u > "$SD/tc3.id"; echo l > "$SD/tc3.log"; old "$SD/tc3.id" "$SD/tc3.log"
sleep 0.3 & DEAD1=$!; wait "$DEAD1" 2>/dev/null
mkdir -p "$SD/tc3.active.lock"
printf '%s' "$DEAD1" > "$SD/tc3.active.lock/owner"
OUT="$(bash "$CLEANUP" --older-than 30 --apply 2>&1)"; RC=$?
[[ ! -e "$SD/tc3.id" && -f "$(last_archive)/tc3.id" ]] && ok "dead-owner lock reclaimed, unit archived" || bad "dead-owner reclaim failed: $OUT"
[[ ! -d "$SD/tc3.active.lock" ]] && ok "reclaimed lock released after apply" || bad "lock left behind"

echo "== hard root anchoring: cleanup outside a git repo -> exit 7, nothing moved =="
NONGIT="$T/nongit"; mkdir -p "$NONGIT/.claude/codex-threads"
printf 'boom\n' > "$NONGIT/.claude/codex-threads/z1.last-error.jsonl"
OUT="$( cd "$NONGIT" && CLAUDE_PROJECT_DIR="$NONGIT" bash "$CLEANUP" --apply 2>&1 )"; RC=$?
[[ "$RC" -eq 7 ]] && ok "cleanup outside a repo -> exit 7" || bad "non-git cleanup rc=$RC out=$OUT"
[[ -f "$NONGIT/.claude/codex-threads/z1.last-error.jsonl" ]] && ok "non-repo state untouched" || bad "non-repo state was moved"

summary
