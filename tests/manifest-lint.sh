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
# The checks are deliberately structural — a delimiter and a fence either
# balance or they do not — with ONE value assertion:
# `disable-model-invocation: true`. Presence alone is not the invariant there,
# since `false` would re-enable model-triggered paid dispatches while the lint
# stayed green. Everything else is left to the Claude Code loader, so this file
# cannot drift from it.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

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
for f in "$ROOT"/plugins/cc-codex-triage/commands/*.md; do
  # disable-model-invocation is the load-bearing one: every command here spends
  # real money, so all of them are user-invoked only.
  check_manifest "$f" description allowed-tools disable-model-invocation=true
done

echo "== skills =="
for f in "$ROOT"/plugins/cc-codex-triage/skills/*/SKILL.md; do
  check_manifest "$f" name description
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
