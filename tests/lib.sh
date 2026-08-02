#!/usr/bin/env bash
# Shared harness for every suite in tests/. Source it, call ok/bad, end with
# `summary`.
#
# It exists because the five suites each carried their own copy, and the copies
# drifted: manifest-lint dropped the per-check "ok:" line the others print, so
# the same run read as silent there and verbose everywhere else.
#
# ok() takes a message like bad() does, and prints it unless CC_TEST_QUIET=1 —
# a suite with a hundred structural checks per file wants the count, not the
# roll-call, and that is a flag rather than a different harness.

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ "${CC_TEST_QUIET:-0}" = "1" ] || echo "  ok: ${1:-}"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: ${1:-}"; }

# Final line and exit status. Every suite prints exactly this, so a caller can
# read all five the same way.
summary() {
  echo
  echo "PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ]
}
