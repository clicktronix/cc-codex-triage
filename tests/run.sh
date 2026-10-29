#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for script in "$ROOT"/plugins/cc-codex-triage/scripts/*.sh "$ROOT"/tests/*.sh; do
  bash -n "$script"
done
bash "$ROOT/tests/manifest-lint.sh"
bash "$ROOT/tests/driver-regression.sh"
bash "$ROOT/tests/review-contract-regression.sh"
python3 "$ROOT/tests/product-integrity.py"
command -v claude >/dev/null || { echo "claude CLI not found: the threads-pane mod cannot be validated or tested" >&2; exit 1; }
claude plugin validate --strict "$ROOT/plugins/cc-codex-triage"
claude plugin test "$ROOT/plugins/cc-codex-triage"
