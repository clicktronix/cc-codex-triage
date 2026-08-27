#!/usr/bin/env bash
# Structural lint for every command and skill manifest.
# Usage: bash tests/manifest-lint.sh   (exit 0 = all pass)
#
# WHY THIS EXISTS. A bulk edit that inserted a paragraph into six command files
# anchored on the wrong delimiter and split the OPENING `---` of four of them
# into `--` + prose + `-`. Those four commands shipped with no frontmatter at
# all — and frontmatter is not decoration here: `disable-model-invocation: true`
# is what keeps a paid Codex dispatch from being callable by the model without
# the user asking. Four suites and 487 tests were green throughout, because
# every one of them tests behaviour and nothing read the manifests.
#
# The checks are deliberately structural. Paid commands remain user-only except
# `/review`, whose model-invocable contract is intentional and tested here.
# Every Bash grant is also limited to bundled plugin scripts.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC_TEST_QUIET=1   # 130+ structural checks per run: the count is the signal
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

check_manifest() { # $1=file  $2..=required frontmatter keys
  local f="$1"; shift
  local rel="${f#$ROOT/}"

  # 1. The file OPENS with the delimiter. A `--`, a blank line, or a BOM here is
  #    the exact corruption this suite exists for.
  if [[ "$(head -1 "$f")" == "---" ]]; then ok; else
    bad "$rel: line 1 is $(head -1 "$f" | cut -c1-20)…, expected ---"
    return
  fi

  # 2. The frontmatter CLOSES. Without this an unterminated block swallows the
  #    whole document.
  local close
  close="$(awk 'NR>1 && /^---$/{print NR; exit}' "$f")"
  if [[ -n "$close" ]]; then ok; else
    bad "$rel: frontmatter never closed"
    return
  fi

  # 3. Every required key is present INSIDE the frontmatter, not merely
  #    somewhere in the prose below it. A requirement written `key=value`
  #    asserts the VALUE too: for disable-model-invocation, presence is not the
  #    invariant — `false` would re-enable model-triggered paid dispatches while
  #    a presence-only check stayed green, which is the same "a check that
  #    cannot fail" trap this suite exists to catch.
  local key want
  for key in "$@"; do
    want=""
    case "$key" in *=*) want="${key#*=}"; key="${key%%=*}" ;; esac
    if ! awk -v c="$close" -v k="^$key:" 'NR>1 && NR<c && $0 ~ k {found=1} END{exit !found}' "$f"; then
      bad "$rel: missing frontmatter key '$key'"
      continue
    fi
    ok
    [[ -n "$want" ]] || continue
    local got
    got="$(awk -v c="$close" -v k="^$key:[[:space:]]*" 'NR>1 && NR<c && $0 ~ k {sub(k,"",$0); print; exit}' "$f" \
           | tr -d '"'"'"' \t\r')"
    if [[ "$got" == "$want" ]]; then ok; else
      bad "$rel: $key is '$got', must be '$want'"
    fi
  done

  # 4. Code fences balance.
  local fences
  fences="$(grep -c '^[[:space:]]*```' "$f")"
  if [[ $((fences % 2)) -eq 0 ]]; then ok; else
    bad "$rel: $fences code fences — unbalanced"
  fi

  # 5. No fence was SPLIT from its language tag. Parity alone cannot see this:
  #    breaking ```bash into ``` + a bare `bash` line leaves the fence count
  #    unchanged and perfectly balanced, while the tag becomes the block's first
  #    line of "code" — which is precisely what happened to review.md and what a
  #    parity-only check waved through. An opening fence with no info string
  #    followed by nothing but a language token is that break.
  if awk '
      /^[[:space:]]*```/ {
        info = $0; sub(/^[[:space:]]*```/, "", info)
        if (open) { open = 0; next }        # this one closes
        open = 1; bare = (info ~ /^[[:space:]]*$/)
        next
      }
      # `bare` persists for the whole block rather than only the first line:
      # in the production break, inserted prose sat BETWEEN the orphaned fence
      # and its stranded `bash` tag, so a first-line-only test missed the very
      # file it was written for.
      open && bare && $0 ~ /^[[:space:]]*(bash|sh|shell|json|jsonl|python|js|ts|yaml|yml|diff|text|md|markdown)[[:space:]]*$/ {
        print NR; exit 1
      }
    ' "$f" >/dev/null; then ok; else
    bad "$rel: a code fence looks split from its language tag (bare tag line inside a block)"
  fi
}

echo "== commands =="
EXPECTED_COMMANDS="ask debate plan reply review status thread thread-list thread-new"
ACTUAL_COMMANDS="$(for f in "$ROOT"/plugins/cc-codex-triage/commands/*.md; do basename "$f" .md; done | sort | tr '\n' ' ' | sed 's/ $//')"
[[ "$ACTUAL_COMMANDS" == "$EXPECTED_COMMANDS" ]] \
  && ok \
  || bad "command surface is '$ACTUAL_COMMANDS', expected '$EXPECTED_COMMANDS'"
for f in "$ROOT"/plugins/cc-codex-triage/commands/*.md; do
  if [[ "$(basename "$f")" == review.md ]]; then
    check_manifest "$f" description allowed-tools
    if awk 'NR>1 && /^---$/{exit} /^disable-model-invocation:/{found=1} END{exit found?0:1}' "$f"; then
      bad "commands/review.md: must remain model-invocable (remove disable-model-invocation)"
    else
      ok
    fi
    allowed="$(awk 'NR>1 && /^---$/{exit} /^allowed-tools:/{sub(/^allowed-tools:[[:space:]]*/, ""); print; exit}' "$f")"
    expected='Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-state.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh *)'
    [[ "$allowed" == "$expected" ]] \
      && ok \
      || bad "commands/review.md: model-invoked Bash grant is '$allowed', expected the three product-route scripts"
  else
    # Every other command stays user-invoked; do not blanket-enable paid tools.
    check_manifest "$f" description allowed-tools disable-model-invocation=true
  fi
  allowed="$(awk 'NR>1 && /^---$/{exit} /^allowed-tools:/{sub(/^allowed-tools:[[:space:]]*/, ""); print; exit}' "$f")"
  if [[ "$allowed" == *Bash* && "$allowed" != *'${CLAUDE_PLUGIN_ROOT}/scripts/'* ]]; then
    bad "${f#$ROOT/}: Bash permission is not scoped to bundled scripts"
  else
    ok
  fi
  if [[ "$allowed" == *'${CLAUDE_PLUGIN_ROOT}/scripts/*)'* ]]; then
    bad "${f#$ROOT/}: Bash permission grants every bundled script"
  else
    ok
  fi
done

echo "== command routing boundaries =="
for command in ask reply thread; do
  file="$ROOT/plugins/cc-codex-triage/commands/$command.md"
  if grep -q 'scripts/codex-thread\.sh' "$file" && ! grep -q 'scripts/dispatch\.sh' "$file"; then
    ok
  else
    bad "commands/$command.md must use the foreground driver directly"
  fi
done
for command in review plan debate; do
  file="$ROOT/plugins/cc-codex-triage/commands/$command.md"
  grep -q 'scripts/dispatch\.sh' "$file" \
    && ok \
    || bad "commands/$command.md must use the long-dispatch wrapper"
done

ASK_ALLOWED="$(awk 'NR>1 && /^---$/{exit} /^allowed-tools:/{sub(/^allowed-tools:[[:space:]]*/, ""); print; exit}' "$ROOT/plugins/cc-codex-triage/commands/ask.md")"
[[ "$ASK_ALLOWED" == 'Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh *)' ]] \
  && ok \
  || bad "commands/ask.md must grant only the driver it executes"

REPLY_ALLOWED="$(awk 'NR>1 && /^---$/{exit} /^allowed-tools:/{sub(/^allowed-tools:[[:space:]]*/, ""); print; exit}' "$ROOT/plugins/cc-codex-triage/commands/reply.md")"
EXPECTED_REPLY='Read, Bash(${CLAUDE_PLUGIN_ROOT}/scripts/state-dir.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/thread-name.sh *), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh *)'
[[ "$REPLY_ALLOWED" == "$EXPECTED_REPLY" ]] \
  && ok \
  || bad "commands/reply.md must retain Read plus its three product-route scripts"

REVIEW_COMMAND="$ROOT/plugins/cc-codex-triage/commands/review.md"
grep -qF '${CLAUDE_PLUGIN_ROOT}/skills/codex-triage/references/review-lenses.md' "$REVIEW_COMMAND" \
  && ok \
  || bad "commands/review.md must resolve its lens reference from CLAUDE_PLUGIN_ROOT"
grep -qF '${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh" "$THREAD" --strict' "$REVIEW_COMMAND" \
  && ok \
  || bad "commands/review.md must express strict mutation policy as a driver flag"
if grep -R -qE '(^|[[:space:]])\.\./skills/' "$ROOT/plugins/cc-codex-triage/commands"; then
  bad "command bodies must not resolve plugin references relative to the project cwd"
else
  ok
fi

THREAD_COMMAND="$ROOT/plugins/cc-codex-triage/commands/thread.md"
grep -q 'Parse leading `--oneshot` and `--topic <text>` flags, in either order' "$THREAD_COMMAND" \
  && ok \
  || bad "commands/thread.md must parse both advertised leading flags"
THREAD_NEW="$ROOT/plugins/cc-codex-triage/commands/thread-new.md"
if grep -q -- '--reset-only' "$THREAD_NEW" && ! grep -q -- ' --new ' "$THREAD_NEW"; then
  ok
else
  bad "commands/thread-new.md must reset only, without starting a paid dispatch"
fi

SKILL="$ROOT/plugins/cc-codex-triage/skills/codex-triage/SKILL.md"
grep -q '`dispatch\.sh --watch`' "$SKILL" \
  && ! grep -q 'printed `detach-watch\.sh`' "$SKILL" \
  && ok \
  || bad "the long-dispatch handoff must stay behind the already-granted dispatch.sh route"

echo "== skills =="
SKILL_COUNT="$(find "$ROOT/plugins/cc-codex-triage/skills" -name SKILL.md -type f | wc -l | tr -d ' ')"
[[ "$SKILL_COUNT" == 1 ]] && ok || bad "expected one routing skill, found $SKILL_COUNT"
for f in "$ROOT"/plugins/cc-codex-triage/skills/*/SKILL.md; do
  check_manifest "$f" name description
done

[[ ! -e "$ROOT/plugins/cc-codex-triage/hooks/hooks.json" ]] \
  && ok || bad "optional Stop-hook subsystem was re-registered"

echo "== required runtime helpers =="
for helper in scripts/review-state.sh scripts/codex-thread.sh scripts/dir-lock.sh scripts/round-counter.sh \
              scripts/state-dir.sh scripts/status.sh scripts/thread-name.sh scripts/verdict.sh; do
  path="$ROOT/plugins/cc-codex-triage/$helper"
  if [[ -f "$path" && -x "$path" ]] \
      && git -C "$ROOT" ls-files --error-unmatch -- "plugins/cc-codex-triage/$helper" >/dev/null 2>&1; then
    ok
  else
    bad "plugins/cc-codex-triage/$helper must be tracked and executable"
  fi
done

summary
