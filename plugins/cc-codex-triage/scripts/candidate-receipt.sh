#!/usr/bin/env bash
# Source in the driver while its dispatch lease is held. Clean Git content is
# identified by HEAD/tree; these endpoint checks are not a continuous snapshot.
required_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
required_identity_matches() {
  local status head tree
  status="$(git status --porcelain -uall --ignore-submodules=none)" || return 1
  head="$(git rev-parse --verify HEAD)" || return 1
  tree="$(git rev-parse --verify 'HEAD^{tree}')" || return 1
  [[ -z "$status" && "$head" == "$REQUIRED_HEAD" && "$tree" == "$REQUIRED_TREE" ]]
}
required_receipt_write() {
  local temporary
  temporary="$(mktemp "$REQUIRED_RECEIPT.tmp.XXXXXX")" || return 1
  if printf 'claim_token=%s\nhead=%s\ntree=%s\nstatus=%s\n' \
      "$REQUIRED_CLAIM" "$REQUIRED_HEAD" "$REQUIRED_TREE" "$1" > "$temporary" \
      && mv -f "$temporary" "$REQUIRED_RECEIPT"; then return 0; fi
  rm -f "$temporary"
  return 1
}
required_dispatch_start() {
  REQUIRED_CLAIM=""
  local candidate="$STATE_DIR/$THREAD.candidate" path
  REQUIRED_RECEIPT="$STATE_DIR/$THREAD.dispatch-receipt"
  for path in "$REQUIRED_RECEIPT" "$STATE_DIR/$THREAD.approved" "$candidate" "$STATE_DIR/$THREAD.last-usage.json" "$STATE_DIR/$THREAD.last-usage.json.tmp"; do
    [[ ! -L "$path" && ( ! -e "$path" || -f "$path" ) ]] || return 7
  done
  # The review mutex serializes the charge with begin, even for an ordinary
  # dispatch racing the first claim. The worker already owns the dispatch lease.
  local decision
  decision="$(CC_REVIEW_WORKER_PID="$$" bash "$SELF_DIR/review-state.sh" charge "$THREAD" <<< "$PROMPT")" || return $?
  if [[ "$decision" == NO_REQUIRED_CLAIM ]]; then
    rm -f "$STATE_DIR/$THREAD.approved" "$REQUIRED_RECEIPT" || return 7
    return 0
  fi
  REQUIRED_CLAIM="$(required_field "$REQUIRED_RECEIPT" claim_token)"
  REQUIRED_HEAD="$(required_field "$REQUIRED_RECEIPT" head)"
  REQUIRED_TREE="$(required_field "$REQUIRED_RECEIPT" tree)"
  [[ -n "$REQUIRED_CLAIM" && -n "$REQUIRED_HEAD" && -n "$REQUIRED_TREE" ]] || return 7
}
required_dispatch_finish() {
  [[ -n "$REQUIRED_CLAIM" ]] || return 0
  if ! required_identity_matches; then
    echo "STALE: candidate changed during required dispatch; the reply remains evidence, not approval" >&2
    return 11
  fi
  required_receipt_write complete
}
