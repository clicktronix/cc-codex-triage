#!/usr/bin/env bash
# Filter for diagnostic tails printed into a caller's transcript: API keys, bearer tokens and
# credential-looking assignments are masked, keeping a short prefix so the operator can still
# tell which key failed. The saved diagnostic files are left intact under the private state dir.
exec sed -E \
  -e 's/(sk-[A-Za-z0-9]{2,6})[A-Za-z0-9_*.…-]{6,}/\1…[redacted]/g' \
  -e 's/([Bb]earer )[A-Za-z0-9._~+\/-]{12,}=*/\1[redacted]/g' \
  -e 's/((api[_-]?key|token|secret|password)(\\*["'"'"'])?[[:space:]]*[:=][[:space:]]*(\\*["'"'"'])?)[^"'"'"'\\[:space:],}]{8,}/\1[redacted]/gI'
