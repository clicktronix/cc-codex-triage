---
description: Force-reset a named Codex thread — next message to it starts a fresh `codex exec` and loses prior conversation memory.
argument-hint: "<thread-name> [optional first message]"
allowed-tools: Bash
disable-model-invocation: true
---

# /thread-new

Drops the saved session UUID for the named thread so the next dispatch starts fresh. The Codex-side rollout file in `~/.codex/sessions/` is NOT deleted (Codex CLI manages those) — only the local pointer is cleared.

## Steps

1. Parse first token from `$ARGUMENTS` as the thread name. Validate `[a-zA-Z0-9_.-]+`.

2. If no further text after the name → just drop the pointer:

   ```bash
   cd "$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel)"   # resolves a subdir candidate UP to the repo root — state lives at the ROOT
   D=".claude/codex-threads"
   # Reset the pointer/counter AND the per-task sidecars, so a reused thread
   # name never inherits the previous task's findings/scope/approval baseline.
   rm -f "$D/<NAME>.id" "$D/<NAME>.rounds" "$D/<NAME>.findings.jsonl" "$D/<NAME>.scope" "$D/<NAME>.approved"
   echo "Thread '<NAME>' reset. Next /thread <NAME>, /review, or /plan invocation starts fresh."
   ```

3. If an additional prompt is given on the same line → drop the pointer AND immediately fire the prompt with `--new`:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/codex-thread.sh" <NAME> --new <<< "<REST_OF_ARGUMENTS>"
   ```

4. Show Codex's reply (if step 3 ran) or the reset confirmation (if step 2 ran).

## When to use

- Codebase has drifted significantly from when the thread started — old context is now misleading.
- Resume failure (exit code 4 from the driver) — the saved UUID points at a dead session.
- You want to A/B compare a fresh Codex take vs the running thread's view.
