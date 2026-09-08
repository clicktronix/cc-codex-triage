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
