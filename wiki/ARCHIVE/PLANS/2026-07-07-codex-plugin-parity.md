# Codex-plugin parity upgrades — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold four ideas from OpenAI's `openai/codex-plugin-cc` into `cc-codex-triage` — GPT-5-style XML-block prompt contracts, native structured JSON review output, first-class `--model`/`--effort` flags, and background dispatch — without regressing the plugin's triage-dialogue strengths (lenses, iterate-to-APPROVE, judge-mode, ledger, autoreview/autoplan gates).

**Architecture:** Four independent, individually-shippable tasks plus a release task. Two touch only prompt/command *markdown* (Tasks 1, 3) and are verified by inspection + a live Codex smoke dispatch. Two touch *bash scripts* (Tasks 2, 4) and get real regression tests on the existing stub-`codex` harness. Task 4 (structured output) consumes the `--schema` driver flag added in Task 2.

**Tech Stack:** bash 3.2 (macOS floor) + POSIX tools, `jq` (ledger, optional-degrade), `codex` CLI ≥ 0.137.0 (0.142+ for `--output-schema`), markdown command/skill files, Claude Code plugin manifest JSON.

## Global Constraints

- **Portability:** every script must run on macOS bash 3.2.57 and Linux. `set -u` (never `set -e` in the driver — it already uses `set -euo pipefail` deliberately; match the surrounding file's choice per-file). No GNU-only flags without a BSD fallback (see `lib.sh:_mtime`).
- **Fail-closed:** a git/jq/fs error must never read as success (clean tree, empty findings, created state). Mirror the existing driver/ledger discipline.
- **No new hard dependency:** `jq` stays optional (ledger degrades); `--output-schema` requires codex ≥ 0.142 — degrade with a clear message on older CLIs, do not hard-require.
- **Backward compatible:** default behaviour of every command is unchanged. All four features are opt-in (`--json`, `--model`, `--effort`, `--background`) or transparent internal refactors (XML lens templates).
- **Thread stability:** the driver omits **model/effort** overrides on `codex exec resume` (kept stable across the thread; WARN if passed). **`--output-schema` is different** — it shapes a single message, and `codex exec resume` accepts it (verified on codex 0.142.5), so it IS passed on resume.
- **Gate invariant:** the `/autoreview` Stop hook matches a *standalone text verdict line* in the REPLY. Codex JSON (`"verdict":"APPROVE"`) does NOT match, so a `--json` reply cannot false-release the gate — but it also cannot *release* it. The gate always dispatches text-mode `/review --once`; manual `/review --json` warns when it targets the armed autoreview thread (paid but non-releasing pass).
- **Commit convention:** short imperative subjects. **No `Co-Authored-By` trailer. No Claude attribution** in commits or PRs.
- **Version:** this is an additive feature release → minor bump `0.6.0 → 0.7.0`.

## Design decisions (resolved defaults — override at plan review)

| # | Decision | Chosen default | Why |
|---|---|---|---|
| D1 | XML blocks: which prompts? | All 6 review + 5 plan lenses + the shared output contract, refactored into a reusable `<block>` library in `review-lenses.md`. Keep every existing invariant (verdict literal, `file:line` citation, "exhaustive per class"). | The block library is DRY (OpenAI splits blocks from recipes); invariants are load-bearing for the ledger + gate. |
| D2 | Structured output: replace or add? | **Add** an opt-in `--json` mode — a single structured pass (`--once`) that works on **initial AND resume** (schema is passed on every dispatch path; `codex exec resume` accepts `--output-schema`). Uses a JSON-specific output contract, not Conventional Comments. Default stays human text. | Preserves the verbatim-text UX; makes `--json` work on the common resume path (existing `review-<branch>` thread), not just fresh threads. |
| D3 | Schema vocabulary | Hybrid: keep cc-codex-triage's `verdict` enum (`APPROVE`/`REQUEST_CHANGES`/`COMMENT`) and `severity` (`blocking`/`non-blocking`) so the ledger + gate stay consistent; **add** OpenAI's structured `file`/`line_start`/`line_end`/`confidence`/`recommendation` fields. | Ledger + hook already speak this vocabulary; `confidence` is the net-new triage signal. |
| D4 | `--model`/`--effort`/`--schema` plumbing | Explicit **driver flags**, validated. **model/effort**: initial/oneshot only (thread-stability policy), WARN on resume. **schema**: applied on **every** path incl. resume (per-message output shape, not session config). | Testable on the stub harness; avoids `CC_CODEX_FLAGS` whitespace fragility; schema-on-resume is required for `--json` to work on existing threads. |
| D5 | `--background` scope | `/review` and `/plan` only; implies single-pass (incompatible with the inline iterate loop); launched via Claude Code `Bash(run_in_background:true)`; no script change. | Matches OpenAI's model; the loop needs the reply inline, so background = one dispatch + later pickup. |

## File Structure

- `plugins/cc-codex-triage/skills/codex-triage/references/review-lenses.md` — **rewrite** into: a `## Reusable prompt blocks` section (the XML block library) + each lens expressed as `<task>` + a block list. (Task 1)
- `plugins/cc-codex-triage/scripts/codex-thread.sh` — **modify** the arg loop + dispatch to add `--model`/`--effort` passthrough (initial/oneshot, WARN on resume) and `--schema` passthrough (**every** path incl. resume), with validation. (Task 2)
- `tests/driver-regression.sh` — **extend** the stub `codex` to record argv; add assertions that the new flags are forwarded and validated. (Task 2)
- `plugins/cc-codex-triage/schemas/review-output.schema.json` — **create** the hybrid review schema. (Task 4)
- `plugins/cc-codex-triage/scripts/ledger.sh` — **modify** `create` to accept optional `--confidence`; surface it in `get`/folded records. (Task 4)
- `tests/ledger-regression.sh` — **create** (repo currently has no ledger test); cover `--confidence` round-trip + fail-closed. (Task 4)
- `plugins/cc-codex-triage/commands/review.md` — **modify**: add `--json` (Task 4) and `--background` (Task 3) flags + their steps.
- `plugins/cc-codex-triage/commands/plan.md` — **modify**: add `--background` (Task 3).
- `plugins/cc-codex-triage/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `CHANGELOG.md`, `plugins/cc-codex-triage/README.md` — **modify** for the 0.7.0 release. (Task 5)

---

### Task 1: XML-block prompt contracts for review + plan lenses

Rewrite `review-lenses.md` so the injected INSTRUCTION uses GPT-5-style XML blocks. Pure prompt-template change: the `/review`/`/plan` commands read a lens block and inject it unchanged, so the command code does not change. There is no unit test for a prompt template — verification is inspection + one live Codex dispatch confirming the verdict contract still fires.

**Files:**
- Modify: `plugins/cc-codex-triage/skills/codex-triage/references/review-lenses.md`

**Interfaces:**
- Produces: the same public contract the commands rely on — a per-lens INSTRUCTION block that ends in a `APPROVE | REQUEST_CHANGES | COMMENT` verdict line and requires `file:line` citations. Command files reference lenses by the SAME names (`correctness`, `security`, …); do not rename them.

- [ ] **Step 1: Add the reusable block library.** Insert a `## Reusable prompt blocks` section near the top of `review-lenses.md`, defining each XML block once:

```xml
<!-- output_contract: shared by ALL review lenses. Replaces the prose "Shared review output contract". -->
<output_contract>
Output ONLY findings, in Conventional Comments format:
  <label> [decoration]: <subject>

  <body: what, why it matters, recommended fix>
Labels: issue | suggestion | question | nitpick | praise | todo | chore | note
Decorations: (blocking) | (non-blocking) | (if-minor)
Cite file:line for every finding. Do NOT restate the diff. Do NOT edit files — report only.
Skip nitpicks unless a file has no higher-severity finding; skip praise unless non-obviously well done.
Last line is the verdict: APPROVE | REQUEST_CHANGES | COMMENT. Use REQUEST_CHANGES only when at least one (blocking) finding remains.
Honour AGENTS.md if present.
</output_contract>

<!-- json_output_contract: used ONLY by /review --json. Swaps OUT the output_contract block (never both — contradictory instructions hurt quality). -->
<json_output_contract>
Return your FINAL message as JSON conforming to the provided output schema — nothing else: no prose, no Conventional Comments, no verdict line outside the JSON.
Populate every finding's file, line_start, severity (blocking|non-blocking), confidence (0..1), title, body, and recommendation. Set the top-level verdict to APPROVE | REQUEST_CHANGES | COMMENT.
</json_output_contract>

<grounding_rules>
Ground every claim in the repository context or tool outputs you inspected.
If a point is an inference, label it clearly. Do not assert unsupported certainty.
</grounding_rules>

<dig_deeper_nudge>
Before finalizing, check for second-order failures, empty/null/boundary states, retries, stale state, and rollback paths.
</dig_deeper_nudge>

<verification_loop>
Before finalizing, verify each finding is material and actionable, and that the verdict matches the findings.
</verification_loop>

<exhaustive_per_class>
When you find an instance of a problem class, search for ALL other sites of the same class and list every one in THIS round — do not dole out one per round.
</exhaustive_per_class>
```

- [ ] **Step 2: Express each review lens as `<task>` + block list.** Replace each existing lens block. Example (correctness, the default):

```xml
### correctness (default)

<task>
Deep correctness review against the stated intent. Prioritise logic bugs, unhandled edge cases
(empty/null/boundary/error paths), broken invariants, missing tests for new behaviour, and scope gaps
vs the intent (intended but not implemented).
</task>

Include blocks: <grounding_rules> <exhaustive_per_class> <dig_deeper_nudge> <verification_loop> <output_contract>
```

Apply the same shape to the remaining review lenses, keeping each lens's existing focus text inside `<task>`:
- **security** — `<task>`: the current security checklist. Blocks: `<grounding_rules> <exhaustive_per_class> <output_contract>`.
- **performance** — `<task>`: the current perf checklist + "name the trigger condition (data size, request rate)". Blocks: `<grounding_rules> <output_contract>`.
- **architecture** — `<task>`: the current architecture checklist + "judge against the intent's declared design". Blocks: `<grounding_rules> <output_contract>`.
- **ux** — `<task>`: the current UX checklist. Blocks: `<grounding_rules> <output_contract>`.
- **quick** — `<task>`: "Fast smoke review only … top few findings or 'no blockers found'". Blocks: `<output_contract>` only (no dig-deeper — it's a smoke pass).

- [ ] **Step 3: Express each plan lens as `<task>` + block list.** Plan lenses keep their non-findings format and their own verdict block. Define a `<plan_verdict>` block once (the current "enumerate ALL instances … End with a standalone verdict line: APPROVE | REQUEST_CHANGES | COMMENT") and reference it from all five (`stress-test`, `pre-mortem`, `devils-advocate`, `alternatives`, `adr`), each with its existing instruction inside `<task>`.

- [ ] **Step 4: Verify by inspection.** Re-read the file: every lens name from `review.md`/`plan.md` still resolves; every review lens ends by including `<output_contract>` (which carries the verdict line); no lens lost its original focus text. Run:

```bash
grep -nE '^### (correctness|security|performance|architecture|ux|quick|stress-test|pre-mortem|devils-advocate|alternatives|adr)' plugins/cc-codex-triage/skills/codex-triage/references/review-lenses.md
```
Expected: all 11 lens headings present.

- [ ] **Step 5: Live smoke (one dispatch).** On a scratch branch with a trivial diff, run the driver with the new correctness block as the prompt and confirm Codex still returns a `file:line` finding and a final `APPROVE|REQUEST_CHANGES|COMMENT` line:

```bash
printf '%s\n' "$(sed -n '/### correctness/,/^### /p' plugins/cc-codex-triage/skills/codex-triage/references/review-lenses.md)" \
  | bash plugins/cc-codex-triage/scripts/codex-thread.sh smoke-lens --oneshot
```
Expected: output ends in one of `APPROVE`/`REQUEST_CHANGES`/`COMMENT`.

- [ ] **Step 6: Commit.**

```bash
git add plugins/cc-codex-triage/skills/codex-triage/references/review-lenses.md
git commit -m "Restructure review/plan lenses as XML-block prompt contracts"
```

---

### Task 2: Driver runtime flags `--model` / `--effort` / `--schema`

Add three passthrough flags to the driver, applied on initial + oneshot dispatch only, validated, with a WARN when passed on a resume (where codex fixes them at session creation). `--schema` is wired here but consumed in Task 4.

**Files:**
- Modify: `plugins/cc-codex-triage/scripts/codex-thread.sh`
- Test: `tests/driver-regression.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: driver CLI accepts `--model <m>`, `--effort <none|minimal|low|medium|high|xhigh>`, `--schema <FILE>`. `-m`/`-c model_reasoning_effort=` apply on initial/oneshot only (WARN + ignored on resume — thread-stability policy). `--output-schema <FILE>` applies on **all** paths incl. resume (per-message output shape; `codex exec resume` accepts it). New exit `1` on invalid effort or a missing `--schema` file.

- [ ] **Step 1: Write the failing tests.** Extend the stub `codex` in `tests/driver-regression.sh` to record its argv, then assert forwarding. Add near the stub definition:

```bash
# record argv so tests can assert the driver forwarded flags to codex
printf '%s\0' "$@" > "${FAKE_CODEX_ARGV:-/dev/null}"
```

Add these cases before the final `PASS=`/`FAIL=` summary:

```bash
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

echo "== model/effort IGNORED + WARN on resume; schema IS forwarded on resume =="
rm -rf "$SD"; run t10                       # initial creates .id
FAKE_CODEX_ARGV="$T/argv2" run t10 --model gpt-5.5
argv2="$(tr '\0' '\n' < "$T/argv2")"
grep -qx 'gpt-5.5' <<<"$argv2" && bad "model leaked into resume" || ok "model not forwarded on resume"
grep -qi 'ignored on resume' "$T/err" && ok "resume WARN emitted for model" || bad "no resume WARN"
echo '{}' > "$T/s.json"
FAKE_CODEX_ARGV="$T/argv3" run t10 --schema "$T/s.json"
argv3="$(tr '\0' '\n' < "$T/argv3")"
grep -qx -- '--output-schema' <<<"$argv3" && ok "--schema forwarded on resume" || bad "schema dropped on resume"
grep -qi 'ignored on resume' "$T/err" && bad "schema wrongly warned as ignored" || ok "no false resume WARN for schema"
unset FAKE_CODEX_ARGV
```

- [ ] **Step 2: Run tests, verify they fail.**

Run: `bash tests/driver-regression.sh`
Expected: FAIL on the new cases (flags unknown → the driver's `-*` catch-all exits 1 before dispatch).

- [ ] **Step 3: Parse the flags.** In the arg loop of `codex-thread.sh`, add vars `MODEL=""` `EFFORT=""` `SCHEMA=""` beside the existing `FORCE_NEW`/`ONESHOT` decls, and add cases before the `-*)` catch-all:

```bash
    --model)  [[ $# -ge 2 ]] || { echo "--model needs a value" >&2; exit 1; }; MODEL="$2"; shift 2 ;;
    --effort) [[ $# -ge 2 ]] || { echo "--effort needs a value" >&2; exit 1; }; EFFORT="$2"; shift 2 ;;
    --schema) [[ $# -ge 2 ]] || { echo "--schema needs a value" >&2; exit 1; }; SCHEMA="$2"; shift 2 ;;
```

- [ ] **Step 4: Validate.** After the existing mutual-exclusion checks, add:

```bash
if [[ -n "$EFFORT" ]]; then
  case "$EFFORT" in none|minimal|low|medium|high|xhigh) ;; *)
    echo "--effort must be none|minimal|low|medium|high|xhigh" >&2; exit 1 ;;
  esac
fi
[[ -z "$SCHEMA" || -f "$SCHEMA" ]] || { echo "--schema file not found: $SCHEMA" >&2; exit 1; }
```

- [ ] **Step 5: Build the overrides array.** After `read -r -a EXTRA_FLAGS <<< "${CC_CODEX_FLAGS:-}"`, add:

```bash
# model/effort: initial/oneshot ONLY (kept stable across the thread; WARN if passed
# on resume). schema: a per-MESSAGE output shape — `codex exec resume` accepts
# --output-schema, so it applies on EVERY path (initial, oneshot, AND resume).
OVERRIDES=()
[[ -n "$MODEL"  ]] && OVERRIDES+=( -m "$MODEL" )
[[ -n "$EFFORT" ]] && OVERRIDES+=( -c "model_reasoning_effort=$EFFORT" )
SCHEMA_ARGS=()
[[ -n "$SCHEMA" ]] && SCHEMA_ARGS+=( --output-schema "$SCHEMA" )
```

- [ ] **Step 6: Apply per path.** In the `$ONESHOT` and `else` (initial) `codex exec` invocations, add `${OVERRIDES[@]+"${OVERRIDES[@]}"} ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"}` right after `${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}`. In the resume branch (`elif [[ -n "$SID" ]]`), add **only** `${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"}` to the `codex exec resume` call (schema is a per-message shape), and WARN only for the session-fixing overrides:

```bash
  if [[ -n "$MODEL$EFFORT" ]]; then
    echo "WARN: --model/--effort are ignored on resume (kept stable across the thread). Use --new to change them." >&2
  fi
```

- [ ] **Step 7: Run tests, verify they pass.**

Run: `bash tests/driver-regression.sh`
Expected: `PASS=… FAIL=0`.

- [ ] **Step 8: Thread the flags through the commands.** In `review.md` and `plan.md` step 1 (flag parsing), document `--model <m>` and `--effort <e>` and pass them to the driver invocation (`bash "…/codex-thread.sh" <THREAD> --model <m> --effort <e> …`). Add them to each command's `argument-hint`. (`--schema` stays internal, driven by `--json` in Task 4.)

- [ ] **Step 9: Commit.**

```bash
git add plugins/cc-codex-triage/scripts/codex-thread.sh tests/driver-regression.sh \
        plugins/cc-codex-triage/commands/review.md plugins/cc-codex-triage/commands/plan.md
git commit -m "Add --model/--effort/--schema driver flags (initial/oneshot; warn on resume)"
```

---

### Task 3: `--background` dispatch for `/review` and `/plan`

Let a review/plan run detached so Claude stays responsive on a large diff. No script change — it uses Claude Code's `Bash(run_in_background:true)`. Background implies a single pass (the inline iterate-to-APPROVE loop needs the reply in-flow).

**Files:**
- Modify: `plugins/cc-codex-triage/commands/review.md`
- Modify: `plugins/cc-codex-triage/commands/plan.md`

**Interfaces:**
- Produces: `/review --background` / `/plan --background` launch the driver detached, print a "started — will surface when done" line, and do not loop. On completion the harness re-invokes; the model then shows the reply and (for `/review`) proceeds to the validate-findings step.

- [ ] **Step 1: Add the flag to parsing + hint.** In `review.md` and `plan.md` step 1, add `--background` to the flag list and to `argument-hint`. Document: "implies a single pass (no iterate loop); incompatible with `--continue`."

- [ ] **Step 2: Add the background branch.** In each command's dispatch step (review.md step 5 / plan.md equivalent), add before the normal foreground call:

```markdown
- **If `--background`:** launch the driver detached and return this turn without waiting:
  Bash(command: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <THREAD> <<< "$PROMPT_BODY"`, run_in_background: true)
  Then tell the user: "Codex review started in the background — I'll surface the result when it lands." Do NOT enter the iterate loop (step 8) and do NOT poll this turn.
```

- [ ] **Step 3: Guard incompatible combos.** In step 1, add: "if both `--background` and `--continue` are present, tell the user they conflict and pick `--continue` (foreground) — background is single-pass."

- [ ] **Step 4: Verify by inspection.**

```bash
grep -n 'background' plugins/cc-codex-triage/commands/review.md plugins/cc-codex-triage/commands/plan.md
```
Expected: flag documented in parsing, hint, and dispatch of both files.

- [ ] **Step 5: Live smoke.** Run `/cc-codex-triage:review --background --once` on a scratch diff; confirm the turn returns immediately with the "started in the background" message and the reply surfaces on completion.

- [ ] **Step 6: Commit.**

```bash
git add plugins/cc-codex-triage/commands/review.md plugins/cc-codex-triage/commands/plan.md
git commit -m "Add --background dispatch to /review and /plan (single-pass, detached)"
```

---

### Task 4: Structured JSON review output (`/review --json`)

Opt-in `--json` mode: the driver passes the bundled schema via the Task-2 `--schema` flag, Codex returns schema-conforming JSON, and `/review` renders it as a human findings view AND auto-populates the ledger (with the new `confidence` field). Default text mode and the autoreview gate are untouched.

**Files:**
- Create: `plugins/cc-codex-triage/schemas/review-output.schema.json`
- Modify: `plugins/cc-codex-triage/scripts/ledger.sh`
- Create: `tests/ledger-regression.sh`
- Modify: `plugins/cc-codex-triage/commands/review.md`

**Interfaces:**
- Consumes: driver `--schema <FILE>` (Task 2).
- Produces: `ledger.sh create … --confidence <0..1>` accepted and surfaced in `get`/folded records; `/review --json` mode that renders Codex JSON + records findings with confidence.

- [ ] **Step 1: Create the schema.** Write `plugins/cc-codex-triage/schemas/review-output.schema.json` — cc-codex-triage's verdict/severity vocabulary + OpenAI's structured finding fields:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "additionalProperties": false,
  "required": ["verdict", "summary", "findings"],
  "properties": {
    "verdict": { "type": "string", "enum": ["APPROVE", "REQUEST_CHANGES", "COMMENT"] },
    "summary": { "type": "string", "minLength": 1 },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "title", "body", "file", "line_start", "confidence"],
        "properties": {
          "severity":       { "type": "string", "enum": ["blocking", "non-blocking"] },
          "title":          { "type": "string", "minLength": 1 },
          "body":           { "type": "string", "minLength": 1 },
          "file":           { "type": "string", "minLength": 1 },
          "line_start":     { "type": "integer", "minimum": 1 },
          "line_end":       { "type": "integer", "minimum": 1 },
          "confidence":     { "type": "number", "minimum": 0, "maximum": 1 },
          "recommendation": { "type": "string" }
        }
      }
    }
  }
}
```

- [ ] **Step 2: Write the failing ledger test.** Create `tests/ledger-regression.sh` modelled on `driver-regression.sh` (mktemp repo, `jq` guard, `ok`/`bad`):

```bash
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
```

Run: `bash tests/ledger-regression.sh` → Expected: FAIL (`--confidence` unknown arg).

- [ ] **Step 3: Add `--confidence` to `ledger.sh create`.** In the `create` arg loop, add `--confidence` to the recognised flags, a `conf=""` default, `--confidence) conf="$2" ;;` in the inner case, and validate numeric AND within `0..1` (the schema promises that range) — drop out-of-range/garbage to null:

```bash
    case "$conf" in ''|*[!0-9.]*) conf="" ;; esac
    if [ -n "$conf" ] && ! awk -v c="$conf" 'BEGIN{exit !(c>=0 && c<=1)}'; then conf=""; fi
```

Then add it to the emitted JSON object:

```bash
    jq -cn --arg id "$id" --arg ts "$(ts)" --arg file "$file" --arg line "$line" \
           --arg sev "$sev" --arg label "$label" --arg title "$title" --arg conf "$conf" \
       '{event:"create",id:$id,ts:$ts,file:$file,
         line:($line|if .=="" then null else (tonumber? // .) end),
         severity:$sev,label:$label,title:$title,
         confidence:($conf|if .=="" then null else (tonumber? // null) end),
         status:"open"}' >> "$F"
```

- [ ] **Step 4: Run the ledger test, verify pass.**

Run: `bash tests/ledger-regression.sh` → Expected: `PASS=2 FAIL=0`.

- [ ] **Step 5: Add the `--json` mode to `review.md`.** In step 1, add `--json` (document: "structured output; single pass, implies `--once`; works on initial OR resume; needs codex ≥ 0.142 and `jq`"). Add a step between dispatch and render:

```markdown
- **If `--json`:** a single structured pass (implies `--once`). Build the lens prompt with `<json_output_contract>` in place of `<output_contract>` (never both — contradictory instructions). Pass `--schema "${CLAUDE_PLUGIN_ROOT}/schemas/review-output.schema.json"` to the driver; the driver forwards `--output-schema` on initial AND resume, so this works on an existing `review-<branch>` thread too. **On a `--json` resume, DO re-send `<json_output_contract>` in the prompt** — an explicit exception to the normal "resume doesn't re-paste the lens contract" rule, because earlier rounds on this thread were text-mode and never saw the JSON contract. Codex's reply is JSON — do NOT show it raw:
  1. `jq -e . <<<"$REPLY"` to confirm it parsed; on failure, show the raw reply and stop.
  2. Render a human view: verdict line, then findings sorted by severity then descending confidence, each as `[severity, conf] file:line — title` + body.
  3. For each finding, record it: `ledger.sh create <THREAD> --file <file> --line <line_start> --severity <severity> --title <title> --confidence <confidence>`.
  4. If `<THREAD>` is the armed autoreview thread (`.claude/codex-threads/autoreview.armed` names it), WARN: a `--json` pass is paid but cannot release the text-verdict gate — use text-mode `/review` for the gate.
```

- [ ] **Step 6: Gate interaction (stress-tested).** Confirmed: Codex JSON (`"verdict":"APPROVE"`) does NOT match the hook's standalone-text-verdict regex, so a `--json` reply can neither false-release NOR release the gate. So: (a) the `/autoreview` gate keeps dispatching text-mode `/review --once` (never `--json`); (b) `/review --json` warns on the armed thread (Step 5.4). Confirm the hook has no structured-output handling:

```bash
grep -n 'output-schema' plugins/cc-codex-triage/hooks/stop-hook.sh || echo "hook does not touch structured output (correct)"
```
Expected: no match (the hook never handles `--output-schema`).

- [ ] **Step 7: Live smoke.** `/cc-codex-triage:review --json --once` on a scratch diff → confirm a rendered findings view (not raw JSON) + ledger entries with confidence (`ledger.sh list <thread>`).

- [ ] **Step 8: Commit.**

```bash
git add plugins/cc-codex-triage/schemas/review-output.schema.json \
        plugins/cc-codex-triage/scripts/ledger.sh tests/ledger-regression.sh \
        plugins/cc-codex-triage/commands/review.md
git commit -m "Add opt-in structured JSON review output (--json) with confidence-scored ledger"
```

---

### Task 5: Release 0.7.0

**Files:**
- Modify: `plugins/cc-codex-triage/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `CHANGELOG.md`
- Modify: `plugins/cc-codex-triage/README.md`

- [ ] **Step 1: Bump version.** Set `0.7.0` in `plugin.json` and both fields of `.claude-plugin/marketplace.json`. Verify:

```bash
grep -rn '"version"' plugins/cc-codex-triage/.claude-plugin/plugin.json .claude-plugin/marketplace.json
```
Expected: `0.7.0` ×3.

- [ ] **Step 2: CHANGELOG.** Add a `## [0.7.0] - <today>` entry: Added — XML-block lens contracts, `--model`/`--effort` flags, `--background` dispatch, opt-in `--json` structured output with confidence-scored ledger. Note the gate stays text-mode and `--output-schema` needs codex ≥ 0.142.

- [ ] **Step 3: README.** Update the command list + flags table for the four new capabilities; add codex-version note for `--json`.

- [ ] **Step 4: Full test sweep.**

```bash
bash tests/driver-regression.sh && bash tests/hook-regression.sh && bash tests/ledger-regression.sh
```
Expected: all `FAIL=0`.

- [ ] **Step 5: Commit.**

```bash
git add plugins/cc-codex-triage/.claude-plugin/plugin.json .claude-plugin/marketplace.json \
        CHANGELOG.md plugins/cc-codex-triage/README.md
git commit -m "Release 0.7.0: XML lens contracts, model/effort flags, background, structured JSON output"
```

---

## Self-Review

- **Spec coverage:** Item 1 → Task 1; item 3 (model/effort) → Task 2; item 4 (background) → Task 3; item 2 (structured JSON) → Task 4; release hygiene → Task 5. All four requested items covered.
- **Placeholder scan:** every code step shows real bash/JSON; test steps give exact commands + expected output. No TBD/TODO.
- **Type/name consistency:** driver flags `--model`/`--effort`/`--schema` defined in Task 2 are the same names consumed by Task 4 (`--schema`) and the commands (Task 2 step 8, Task 4 step 5). Ledger `--confidence` defined in Task 4 step 3 is the same flag the test (step 2) and render (step 5) call. Schema `verdict` enum matches the `review-output.schema.json` and the existing hook's verdict vocabulary.
- **Known risks flagged (Codex stress-test, round 1):** (a) schema must pass on resume, not just initial, or `--json` silently no-ops on the common existing-thread path — fixed (Task 2: `SCHEMA_ARGS` on every dispatch path incl. resume, `codex exec resume --output-schema` verified on 0.142.5). (b) `--json` must use `<json_output_contract>`, not the text one — fixed (Task 1 block + Task 4 step 5). (c) `--json` can neither false-release nor release the text gate — reframed (Task 4 step 6 + armed-thread warn).

## Verification layers (the project's review discipline)

After implementation, before merge, run the same multi-layer pass this repo uses on itself: `cc-codex-triage:plan` to stress-test THIS plan first; then per-task `superpowers:requesting-code-review`; then `/code-review`; then `cc-codex-triage:review` to APPROVE. Validate every inbound finding against the code before applying (the plugin's own "validating inbound Codex findings" rule).
