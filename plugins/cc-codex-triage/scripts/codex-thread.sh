#!/usr/bin/env bash
# cc-codex-triage — thread driver.
#
# Sends a prompt to a NAMED Codex thread. First call creates the thread via
# `codex exec` and persists the session UUID; subsequent calls resume the same
# thread via `codex exec resume <UUID>` so Codex retains full conversation
# memory across turns.
#
# Usage:
#   codex-thread.sh <thread-name> [--new | --oneshot] [--require-existing] [--detach]
#       Reads prompt from stdin. Echoes the assistant's final message to stdout.
#       --new               fresh persistent thread, discarding the existing one.
#       --oneshot           throwaway: ignores thread state, runs an ephemeral
#                           exec (no .id, no rollout, no audit log). Mutually
#                           exclusive with --new.
#       --require-existing  fail (exit 6) instead of creating a new thread when
#                           none exists. Used by /reply.
#       --topic <text>      one-line label for a NEW thread, ignored if the
#                           thread already has one. Makes the thread findable
#                           by subject rather than by name alone.
#       --detach            re-exec this dispatch in its OWN SESSION so it
#                           survives group-targeted kills (harness process
#                           reaping); prints `DETACHED pid=<pid>
#                           output=<thread>.detach-output` and returns
#                           immediately. Needs `setsid` or `python3` on PATH.
#                           Mutually exclusive with --oneshot.
#
# Storage (under .claude/codex-threads/ — git-ignore this directory):
#   <thread>.id               UUID of the active session.
#   <thread>.log              append-only audit log (rotated at ~1 MB to .log.1).
#   <thread>.rounds           successful-dispatch counter (reset by --new).
#   <thread>.topic            one-line label of what the thread is about, set
#                             by --topic on the dispatch that creates it and
#                             never overwritten after (cleared by --new). Read
#                             by thread-index.sh so an agent can pick an
#                             existing thread instead of opening a new one.
#   <thread>.last-error.jsonl raw Codex JSONL from the most recent failure
#                             (removed on the next successful dispatch; every
#                             write is capped to the LAST 64 KB of the stream).
#   <thread>.findings.jsonl   /review's findings ledger (per-task; reset by --new).
#   <thread>.scope            /review's pinned scope (per-task; reset by --new).
#   <thread>.approved         /review's last-APPROVE baseline (per-task; reset by --new).
#   <thread>.active           PID lease held while a dispatch is in flight —
#                             acquired BEFORE any existing-thread mutation
#                             (--new's sidecar reset, the invalid-ID discard),
#                             removed on exit only by the PID that wrote it.
#                             Acquisition is EXCLUSIVE and ATOMIC: the whole
#                             claim runs inside the <thread>.active.lock mutex,
#                             a lease naming a live foreign PID refuses the new
#                             dispatch (exit 10); a dead or malformed lease is
#                             stale state and is overwritten.
#   <thread>.active.lock      mkdir mutex serializing lease acquisition (mkdir
#                             is atomic on POSIX). The winner publishes its
#                             PID into <lock>/owner immediately after the
#                             mkdir via a NOCLOBBER (O_EXCL) write — if a
#                             token already exists, the directory was
#                             reclaimed out from under a stalled pre-token
#                             acquirer, which loses (exit 10) without touching
#                             the reclaimer's token. Takeover is
#                             OWNERSHIP-gated, not age-gated: a
#                             lock whose recorded owner is ALIVE is never
#                             stolen (regardless of age); a dead/invalid owner
#                             is reclaimed at once; an ownerless lock older
#                             than 60s (acquirer crashed between mkdir and the
#                             token write) is reclaimed too. Ownership is
#                             re-verified before the lease write, and every
#                             release removes the lock only while <lock>/owner
#                             still names this PID. cleanup() releases a
#                             still-held lock on every exit path.
#   <thread>.detach-output    raw STDOUT of the LATEST --detach child (the
#                             reply echo). Truncated per launch BY THE CHILD
#                             after lease arbitration (only the lease owner
#                             redirects into it — a concurrent exit-10 loser
#                             cannot touch it); the launcher captures
#                             pre-lease output in a private tmpfile. The
#                             .log marker contract above is unchanged.
#   <thread>.detach-stderr    raw STDERR of the LATEST --detach child —
#                             warnings a successful run emits (invalid saved
#                             .id discarded, ignored resume overrides,
#                             porcelain guard notes) live here, split from
#                             the reply so the watcher can deliver them.
#   <thread>.detach-status    the LATEST detach child's real exit status
#                             (`pid=`/`rc=` lines, written atomically by the
#                             child's EXIT trap) — detach-watch.sh decides
#                             success/failure from it, not from log growth.
#
# Exit codes:
#   0   success
#   1   usage error
#   2   codex CLI missing
#   3   codex exec failed (initial or oneshot)
#   4   codex exec resume failed (saved UUID preserved — re-run with --new)
#   5   tracked-file mutation detected (only with CC_CODEX_TRIAGE_STRICT=1)
#   6   --require-existing set but no existing thread
#   7   persistent mode outside a git repository (state anchors to the repo
#       root — cd into a repo, fix CLAUDE_PROJECT_DIR, or use --oneshot)
#   8   --detach: no session isolator (neither `setsid` nor `python3` on
#       PATH) — refused with ZERO state written
#   9   --detach: ready-handshake timed out on a still-ALIVE child (spawn
#       killed, launcher-owned tmpfiles removed; check
#       <thread>.detach-output / <thread>.detach-stderr). A child that
#       EXITS before READY instead has
#       its own exit status harvested and propagated by the launcher (e.g.
#       10 for a busy lease/mutex, a non-regular lease, or a lost claim).
#   10  dispatch refused: could not acquire the thread's lease — another
#       dispatch is mid-flight (<thread>.active names a live PID: wait for
#       it or use a different --thread), a concurrent claim holds the
#       acquisition mutex (<thread>.active.lock — held by a LIVE recorded
#       owner or freshly claimed: retry shortly; only dead-owner or
#       ownerless>60s locks are reclaimed), this acquisition lost the mutex
#       to a concurrent reclaim (before or after publishing its owner
#       token), or <thread>.active is not a regular file (inspect and
#       remove it manually)

set -euo pipefail

# ── args ──────────────────────────────────────────────────────────────────
FORCE_NEW=false
ONESHOT=false
REQUIRE_EXISTING=false
DETACH=false
THREAD=""
MODEL=""
EFFORT=""
SCHEMA=""
TOPIC=""
# Args a --detach launcher forwards to its re-exec'd child: everything except
# --detach itself (the child is an ordinary foreground invocation).
CHILD_ARGS=()
for _a in "$@"; do [[ "$_a" == "--detach" ]] || CHILD_ARGS+=("$_a"); done
while (( $# )); do
  case "$1" in
    --new) FORCE_NEW=true; shift ;;
    --oneshot) ONESHOT=true; shift ;;
    --detach) DETACH=true; shift ;;
    --require-existing) REQUIRE_EXISTING=true; shift ;;
    --model)  [[ $# -ge 2 ]] || { echo "--model needs a value" >&2; exit 1; }; MODEL="$2"; shift 2 ;;
    --effort) [[ $# -ge 2 ]] || { echo "--effort needs a value" >&2; exit 1; }; EFFORT="$2"; shift 2 ;;
    --schema) [[ $# -ge 2 ]] || { echo "--schema needs a value" >&2; exit 1; }; SCHEMA="$2"; shift 2 ;;
    --topic)  [[ $# -ge 2 ]] || { echo "--topic needs a value" >&2; exit 1; }; TOPIC="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)
      # A mistyped flag must not silently become a thread name (and burn a
      # dispatch on it) — the thread-name regex would otherwise accept it.
      echo "unknown flag: $1" >&2; exit 1 ;;
    *)
      if [[ -z "$THREAD" ]]; then THREAD="$1"; shift
      else echo "unknown arg: $1" >&2; exit 1
      fi ;;
  esac
done

[[ -z "$THREAD" ]] && {
  echo "usage: codex-thread.sh <thread-name> [--new | --oneshot] [--require-existing] [--detach]" >&2
  echo "exit codes: 0 ok, 1 usage, 2 no codex CLI, 3 exec failed, 4 resume failed, 5 tracked-file mutation (strict), 6 no existing thread, 7 not a git repo, 8 no --detach isolator, 9 --detach handshake timeout, 10 thread busy (lease or acquisition lock held by a live owner) — see --help" >&2
  exit 1
}
[[ "$THREAD" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "thread name must be [a-zA-Z0-9_.-]+" >&2; exit 1; }
if $FORCE_NEW && $ONESHOT; then
  echo "--new and --oneshot are mutually exclusive (--new resets a persistent thread; --oneshot keeps none)." >&2
  exit 1
fi
if $ONESHOT && $REQUIRE_EXISTING; then
  echo "--oneshot and --require-existing are mutually exclusive (oneshot keeps no thread to require)." >&2
  exit 1
fi
if $DETACH && $ONESHOT; then
  echo "--detach and --oneshot are mutually exclusive (--detach hands off to a persistent re-exec; --oneshot keeps no thread state to hand off)." >&2
  exit 1
fi
if $FORCE_NEW && $REQUIRE_EXISTING; then
  # Order matters: --new deletes the saved UUID before --require-existing is
  # checked — allowing the combo would destroy the very thread it then refuses
  # to use. Refuse up front instead.
  echo "--new and --require-existing are mutually exclusive (--new would discard the thread --require-existing demands)." >&2
  exit 1
fi
if [[ -n "$EFFORT" ]]; then
  case "$EFFORT" in none|minimal|low|medium|high|xhigh) ;; *)
    echo "--effort must be none|minimal|low|medium|high|xhigh" >&2; exit 1 ;;
  esac
fi
# Resolve a relative --schema against the caller's cwd NOW — the anchoring
# `cd "$ROOT"` below changes cwd, and this same $SCHEMA string is forwarded
# to `codex exec --output-schema` after that cd, so a relative path must be
# made absolute before either the existence check or the forward.
[[ -n "$SCHEMA" && "$SCHEMA" != /* ]] && SCHEMA="$PWD/$SCHEMA"
[[ -z "$SCHEMA" || -f "$SCHEMA" ]] || { echo "--schema file not found: $SCHEMA" >&2; exit 1; }

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH. Install: npm install -g @openai/codex" >&2
  exit 2
}

# ── anchor cwd ────────────────────────────────────────────────────────────
# State paths are repo-relative, but the Bash tool's cwd persists across calls
# and can drift into subdirectories. Persistent modes anchor to the RESOLVED
# repo root — the candidate (CLAUDE_PROJECT_DIR or PWD) is passed through
# `git rev-parse --show-toplevel`, so a candidate inside a subdirectory
# resolves UP to the root and driver/hook state can never split. A candidate
# that is not inside a repo (or does not exist) is a hard error: writing state
# to an arbitrary directory is exactly the incident this guards against.
# --oneshot skips resolution entirely — it keeps no repo state.
if ! $ONESHOT; then
  # set -e-safe form: a bare ROOT=$(git ...) failure would exit 128 here,
  # before any check could produce the diagnostic below.
  if ! ROOT="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ]; then
    echo "not inside a git repository (candidate: ${CLAUDE_PROJECT_DIR:-$PWD})." >&2
    echo "Persistent threads anchor their state to the repo root. Fix one of:" >&2
    echo "  - cd into the target repository," >&2
    echo "  - point CLAUDE_PROJECT_DIR at (or inside) a git repository," >&2
    echo "  - or use --oneshot for a state-less dispatch." >&2
    exit 7
  fi
  cd "$ROOT"
fi

# ── detach preflight: select the session isolator ─────────────────────────
# Runs BEFORE any persistent state is created (the mkdir in the paths section
# below): a refused --detach must leave ZERO state behind — no state dir, no
# lease, no tmpfiles. A NEW SESSION is the only thing that survives a
# group-targeted SIGTERM/SIGKILL; plain `nohup` only shields SIGHUP, so it is
# NOT an accepted fallback.
DETACH_ISOLATOR=""
if $DETACH; then
  if command -v setsid >/dev/null 2>&1; then
    DETACH_ISOLATOR="setsid"
  elif command -v python3 >/dev/null 2>&1; then
    DETACH_ISOLATOR="python3"
  else
    echo "--detach needs a session isolator, but neither 'setsid' nor 'python3' is on PATH." >&2
    echo "Install one of them, or dispatch without --detach (foreground, or the harness's run_in_background)." >&2
    exit 8
  fi
fi

# ── paths ─────────────────────────────────────────────────────────────────
STATE_DIR=".claude/codex-threads"
# Create the state dir only for persistent modes. --oneshot leaves no trace in
# the repo, so it must not even create an empty directory; its failure diag goes
# to a temp path instead.
ID_FILE="$STATE_DIR/${THREAD}.id"
LOG_FILE="$STATE_DIR/${THREAD}.log"
ROUNDS_FILE="$STATE_DIR/${THREAD}.rounds"
# Per-task sidecars written by /review (the model), not by this driver. Listed
# here so --new can reset them with the rest of the thread's state.
FINDINGS_FILE="$STATE_DIR/${THREAD}.findings.jsonl"
SCOPE_FILE="$STATE_DIR/${THREAD}.scope"
APPROVED_FILE="$STATE_DIR/${THREAD}.approved"
LEASE_FILE="$STATE_DIR/${THREAD}.active"
# Staging file for the atomic lease write below. Defined up front so the
# combined cleanup() can always remove it — no exit path may leak it.
LEASE_TMP="$STATE_DIR/${THREAD}.active.tmp.$$"
# mkdir mutex serializing lease acquisition; HAVE_LEASE_LOCK tracks whether
# THIS process acquired it so the release helper below runs on every path.
LEASE_LOCK="$STATE_DIR/${THREAD}.active.lock"
HAVE_LEASE_LOCK=false

# Ownership-checked mutex release — the ONE rule for every removal of the
# lock: this process removes it ONLY while <lock>/owner still records $$.
# After a stale takeover robbed us, the dir (and its owner token) belong to
# the new owner and must be left intact; an owner token that vanished out
# from under us is treated the same way (no longer provably ours — the
# ownerless>60s reclaim below will eventually collect it if it was).
release_lease_lock() {
  [[ "$HAVE_LEASE_LOCK" == true ]] || return 0
  if [[ "$(cat "$LEASE_LOCK/owner" 2>/dev/null)" == "$$" ]]; then
    rm -f "$LEASE_LOCK/owner"
    rmdir "$LEASE_LOCK" 2>/dev/null || true
  fi
  HAVE_LEASE_LOCK=false
  return 0
}
if $ONESHOT; then
  DIAG_FILE="${TMPDIR:-/tmp}/cc-codex-${THREAD}.last-error.jsonl"
else
  mkdir -p "$STATE_DIR"
  DIAG_FILE="$STATE_DIR/${THREAD}.last-error.jsonl"
  # One-time hygiene nudge: thread state should never be committed. Warn once
  # per repo (marker file suppresses repeats), only when inside a git repo.
  if git -C . rev-parse --show-toplevel >/dev/null 2>&1 \
     && ! git -C . check-ignore -q "$STATE_DIR/x" 2>/dev/null \
     && [[ ! -f "$STATE_DIR/.gitignore-warned" ]]; then
    echo "HINT: $STATE_DIR is not gitignored — add '.claude/codex-threads/' to .gitignore (these are transient session logs; a 'git add -A' would stage them)." >&2
    touch "$STATE_DIR/.gitignore-warned"
  fi
fi

# Live foreign lease detector: prints the owning PID and returns 0 when
# <thread>.active is a regular file naming a strictly-positive decimal PID
# (≤12 digits, no leading zero — the octal trap) that is alive (`kill -0`)
# and is not this process. Dead/malformed leases return 1 — they are stale
# state and are overwritten by the acquisition below.
lease_busy_pid() {
  [[ -f "$LEASE_FILE" ]] || return 1
  local pid
  pid="$(cat "$LEASE_FILE" 2>/dev/null || true)"
  [[ "$pid" =~ ^[1-9][0-9]{0,11}$ ]] || return 1
  [[ "$pid" != "$$" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

# ── detach launcher ───────────────────────────────────────────────────────
# Re-execs this same script (same args minus --detach) in a NEW SESSION and
# returns after a ready handshake. Lifecycle order is the contract:
#   isolator preflight (above, exit 8 with zero state) → state dir + gitignore
#   nudge (paths section above — the sidecar redirection below is performed by
#   the shell BEFORE the isolator runs, so on a repo's first-ever detach the
#   directory must already exist) → persist stdin + allocate READY → spawn →
#   poll READY.
# The launcher acquires NO lease — only the re-exec'd child (the invocation
# that actually dispatches) does, and the child reports its PID into READY
# only AFTER its lease is held, so a DETACHED report can never race /cleanup.
# The parent OWNS the READY file (the child never deletes it — a child
# finishing faster than one poll interval must not cause a false timeout);
# the child's cleanup owns the prompt tmpfile.
if $DETACH; then
  DETACH_OUT="$STATE_DIR/${THREAD}.detach-output"
  # A live foreign lease means another dispatch is already mid-flight on this
  # thread. The re-exec'd child re-checks under the same exclusive-acquisition
  # rule; checking here too just fails fast (exit 10) instead of burning the
  # 5s handshake timeout on a child that will refuse anyway.
  if BUSY_PID="$(lease_busy_pid)"; then
    echo "thread $THREAD is busy (active dispatch pid=$BUSY_PID) — wait for it or use a different --thread" >&2
    exit 10
  fi
  # Launcher-scoped trap BEFORE the first tmpfile allocation: a failed second
  # mktemp (set -e exit) or a TERM/INT during the handshake must not leak the
  # prompt/READY tmpfiles (the child never removes READY, and on an aborted
  # handshake nobody else would remove the prompt). Disarmed via DETACH_DONE
  # just before the normal-success exit — at that point READY is already gone
  # and the child owns the prompt tmpfile.
  DETACH_DONE=false
  PROMPT_TMPFILE=""; READY_FILE=""; SPAWN_PID=""; SPAWNOUT_TMPFILE=""
  # Settle an ABORTED handshake's spawn: TERM its whole session/process group,
  # then CONFIRM termination (bounded ~2s poll, escalating to KILL) — a
  # delayed child left unsignaled (or TERMed but unconfirmed) could recreate
  # READY after this launcher is gone and keep dispatching ownerless. After a
  # confirmed DETACHED success the child owns itself — that is the feature —
  # so this kill applies only to ABORTED handshakes (DETACH_DONE
  # short-circuits detach_cleanup before it can run).
  # Process-state probe with a broken-ps discriminator. `ps` failing on the
  # TARGET is ambiguous: BSD ps exits non-zero for a zombie it cannot list
  # (target truly gone), but a process-restricted sandbox fails `ps` for
  # EVERY pid — including this shell itself. Probing $$ (always alive) tells
  # the two apart: self listable → the target really is gone/zombie (prints
  # nothing); self unlistable → ps is unusable here, print UNKNOWN and let
  # the caller fall back to kill -0 alone. Always returns 0 (set -e safety).
  proc_state() { # $1=pid → stdout: state chars, '' (gone/zombie-unlistable), or UNKNOWN
    local out
    if out="$(ps -o stat= -p "$1" 2>/dev/null)"; then
      printf '%s' "$out" | tr -d '[:space:]'
      return 0
    fi
    if ps -o stat= -p "$$" >/dev/null 2>&1; then
      : # ps works; the target is unlistable -> gone (empty output)
    else
      printf 'UNKNOWN'
    fi
    return 0
  }
  reap_spawn() {
    [[ -n "$SPAWN_PID" ]] || return 0
    # The spawn is its own session leader (pgid == pid) — kill the whole
    # group; fall back to the bare PID if the group is already gone.
    kill -TERM -"$SPAWN_PID" 2>/dev/null || kill -TERM "$SPAWN_PID" 2>/dev/null || true
    local i=0 st
    while [[ $i -lt 20 ]]; do
      kill -0 "$SPAWN_PID" 2>/dev/null || break
      # kill -0 also succeeds on a zombie (dead, not yet reaped child) — read
      # the real state via proc_state; '' or Z* means it is already gone,
      # UNKNOWN (ps unusable) means keep waiting on kill -0 alone — treating
      # a ps failure as "dead" under a restricted sandbox skipped the KILL
      # escalation for a still-alive child.
      st="$(proc_state "$SPAWN_PID")"
      case "$st" in ''|Z*) break ;; esac
      sleep 0.1
      i=$((i+1))
    done
    if kill -0 "$SPAWN_PID" 2>/dev/null; then
      # UNKNOWN falls through to the KILL escalation (this is the abort
      # path — a possibly-alive child must die, not get the benefit of doubt).
      st="$(proc_state "$SPAWN_PID")"
      case "$st" in ''|Z*) ;; *) kill -KILL -"$SPAWN_PID" 2>/dev/null || kill -KILL "$SPAWN_PID" 2>/dev/null || true ;; esac
    fi
    wait "$SPAWN_PID" 2>/dev/null || true   # reap the zombie
    return 0
  }
  # True while the spawn is still RUNNING. kill -0 alone is not enough: it
  # also succeeds on a zombie (dead, not yet reaped) — read the real state
  # via proc_state; empty or Z* means it is already gone. Without a usable
  # `ps` (missing from PATH, or failing even for $$ under a restricted
  # sandbox → UNKNOWN), trust kill -0 alone: a false "alive" only delays
  # detection by an iteration (bash reaps the background child
  # asynchronously, after which kill -0 fails), while a false "dead" would
  # misreport a healthy child as exited — observed as launcher exit 9/failure
  # storms in a process-restricted sandbox where every `ps` errors.
  spawn_alive() {
    kill -0 "$SPAWN_PID" 2>/dev/null || return 1
    command -v ps >/dev/null 2>&1 || return 0
    local st
    st="$(proc_state "$SPAWN_PID")"
    case "$st" in ''|Z*) return 1 ;; esac
    return 0
  }
  detach_cleanup() {
    "$DETACH_DONE" && return 0
    # Settle the spawn FIRST, only then remove the launcher-owned tmpfiles —
    # the reverse order would leave a window where a still-alive child
    # recreates READY after it was unlinked.
    reap_spawn
    [[ -n "$PROMPT_TMPFILE" ]] && rm -f "$PROMPT_TMPFILE"
    [[ -n "$READY_FILE" ]] && rm -f "$READY_FILE"
    [[ -n "$SPAWNOUT_TMPFILE" ]] && rm -f "$SPAWNOUT_TMPFILE"
    return 0
  }
  trap detach_cleanup EXIT
  trap 'detach_cleanup; trap - EXIT; exit 130' INT
  trap 'detach_cleanup; trap - EXIT; exit 143' TERM
  PROMPT_TMPFILE="$(mktemp "${TMPDIR:-/tmp}/cc-codex-${THREAD}.prompt.XXXXXX")"
  cat > "$PROMPT_TMPFILE"      # persist stdin for the re-exec'd child
  READY_FILE="$(mktemp "${TMPDIR:-/tmp}/cc-codex-${THREAD}.ready.XXXXXX")"
  SPAWNOUT_TMPFILE="$(mktemp "${TMPDIR:-/tmp}/cc-codex-${THREAD}.spawnout.XXXXXX")"
  export CC_CODEX_PROMPT_TMPFILE="$PROMPT_TMPFILE"
  export CC_CODEX_READY_FILE="$READY_FILE"
  # log-offset baseline for detach-watch.sh, measured BEFORE the spawn: the
  # child cannot have appended anything yet, so a fast reply landing before
  # the watcher starts is still counted as growth. (Measuring after the
  # handshake had a race: an instant child could append its reply first.)
  # set -e safety: a missing log (first-ever dispatch) must yield 0.
  LOG_BASE=0
  if [[ -f "$STATE_DIR/${THREAD}.log" ]]; then
    LOG_BASE="$(wc -c < "$STATE_DIR/${THREAD}.log" | tr -d ' ')"
  fi
  case "${LOG_BASE:-}" in ''|*[!0-9]*) LOG_BASE=0 ;; esac
  # The spawn writes to a launcher-owned UNIQUE tmpfile, NOT the canonical
  # sidecar: two near-simultaneous launchers can both pass the preliminary
  # lease check, and truncating a shared path here would let the exit-10
  # loser and the winner interleave/overwrite output. The canonical
  # <thread>.detach-output job boundary is established by the CHILD, after
  # lease arbitration — only the lease OWNER redirects into it (truncating),
  # so the file always holds exactly the winning launch's output. This
  # tmpfile only ever captures PRE-LEASE output (usage errors, busy
  # refusals) and is removed by every launcher exit path.
  if [[ "$DETACH_ISOLATOR" == "setsid" ]]; then
    setsid bash "$0" "${CHILD_ARGS[@]}" \
      < "$PROMPT_TMPFILE" > "$SPAWNOUT_TMPFILE" 2>&1 &
  else
    # No `--` separator: with -c, sys.argv[0] is '-c' — the exec target is
    # sys.argv[1] ('bash').
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
      bash "$0" "${CHILD_ARGS[@]}" \
      < "$PROMPT_TMPFILE" > "$SPAWNOUT_TMPFILE" 2>&1 &
  fi
  SPAWN_PID=$!
  # Handshake: the child writes its PID into READY after acquiring its lease.
  # Bounded 5s in 0.1s steps (bash 3.2 / macOS `sleep 0.1` is fine). Each
  # iteration also watches the spawn itself: a child that EXITS before READY
  # (e.g. a held acquisition mutex or a non-regular lease — refusals only the
  # child can detect) already reported its verdict via its exit status;
  # waiting out the full 5s would misreport it as a timeout.
  CHILD_PID=""
  SPAWN_EXITED=false
  i=0
  while [[ $i -lt 50 ]]; do
    if [[ -s "$READY_FILE" ]]; then
      CHILD_PID="$(cat "$READY_FILE" 2>/dev/null || true)"
      [[ "$CHILD_PID" =~ ^[0-9]+$ ]] && break
      CHILD_PID=""
    fi
    if ! spawn_alive; then
      # Dead spawn: re-check READY once — it may have landed between the
      # check above and the death check (the child writes READY and can
      # finish an instant dispatch within one poll interval) — then stop
      # polling.
      if [[ -s "$READY_FILE" ]]; then
        CHILD_PID="$(cat "$READY_FILE" 2>/dev/null || true)"
        [[ "$CHILD_PID" =~ ^[0-9]+$ ]] || CHILD_PID=""
      fi
      [[ -n "$CHILD_PID" ]] || SPAWN_EXITED=true
      break
    fi
    sleep 0.1
    i=$((i+1))
  done
  if [[ -z "$CHILD_PID" ]]; then
    if [[ "$SPAWN_EXITED" == true ]]; then
      # EARLY CHILD EXIT: harvest and propagate the child's own exit status.
      # `wait` works because the spawn is a DIRECT child of this launcher
      # shell under BOTH isolators: the setsid binary does not fork here (a
      # `&` background spawn of a non-interactive shell is never a process-
      # group leader, so setsid(1) calls setsid(2) in place), and the python
      # one-liner execs the worker in place. No reaping needed — it already
      # exited (bash recorded the status).
      SPAWN_RC=0
      wait "$SPAWN_PID" 2>/dev/null || SPAWN_RC=$?
      # A zero status without READY should be impossible (a persistent child
      # always writes READY before dispatching) — report the generic
      # handshake failure rather than a bogus success.
      [[ "$SPAWN_RC" -eq 0 ]] && SPAWN_RC=9
      echo "--detach child exited early (status $SPAWN_RC) before reporting ready — propagating its exit status." >&2
      if [[ -s "$SPAWNOUT_TMPFILE" ]]; then
        echo "--- child output (pre-lease):" >&2
        tail -c 4096 "$SPAWNOUT_TMPFILE" >&2
      fi
      if [[ -s "$STATE_DIR/${THREAD}.detach-stderr" ]]; then
        # UNATTRIBUTED: a pre-lease loser (exit 10) never truncated the
        # canonical sidecars — this tail may belong to a previous launch or
        # a concurrent winner. Only a child that passed lease acquisition
        # owns it; label accordingly instead of implying ownership.
        echo "--- latest thread stderr (${THREAD}.detach-stderr — only this child's if it passed lease acquisition; otherwise a previous/concurrent launch's):" >&2
        tail -c 4096 "$STATE_DIR/${THREAD}.detach-stderr" >&2
      fi
      rm -f "$READY_FILE" "$PROMPT_TMPFILE" "$SPAWNOUT_TMPFILE"
      DETACH_DONE=true
      exit "$SPAWN_RC"
    fi
    # ABORTED handshake (child alive but unresponsive): TERM the spawn's
    # session group and CONFIRM it is dead (bounded wait, KILL escalation)
    # BEFORE removing the launcher-owned files — an unconfirmed TERM would
    # let a slow child recreate READY.
    reap_spawn
    echo "--detach handshake timed out after 5s: the child never reported ready (spawn killed)." >&2
    if [[ -s "$SPAWNOUT_TMPFILE" ]]; then
      echo "--- child output (pre-lease):" >&2
      tail -c 4096 "$SPAWNOUT_TMPFILE" >&2
    fi
    echo "If the child had passed lease acquisition, its stdout is in $DETACH_OUT and its stderr in ${DETACH_OUT%.detach-output}.detach-stderr" >&2
    rm -f "$READY_FILE" "$PROMPT_TMPFILE" "$SPAWNOUT_TMPFILE"
    exit 9
  fi
  rm -f "$READY_FILE" "$SPAWNOUT_TMPFILE"
  DETACH_DONE=true   # handshake complete — the EXIT trap must not touch the child's prompt tmpfile
  WATCHER_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/detach-watch.sh"
  echo "DETACHED pid=$CHILD_PID output=${THREAD}.detach-output log-offset=$LOG_BASE — for completion delivery run: bash '$WATCHER_PATH' $THREAD $CHILD_PID $LOG_BASE (as a background task); fallback: poll the thread log for the next 'round=' header"
  exit 0
fi

OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/cc-codex-${THREAD}.XXXXXX")"
JSONL_FILE="${OUT_FILE}.jsonl"
# Combined EXIT cleanup — installed exactly ONCE. Never add a second
# `trap ... EXIT`: it would silently replace this one. (The --detach launcher
# above installs its own EXIT trap, but that code path exits before ever
# reaching this line, so the two can never collide.)
DETACH_CHILD=false
cleanup() {
  # $? FIRST — every later command in this trap would clobber it. Publishing
  # the worker's real exit status lets detach-watch.sh decide success from
  # fact, not from log growth (which strict-mutation exit 5 also produces).
  local rc=$?
  if [[ "$DETACH_CHILD" == true ]]; then
    printf 'pid=%s\nrc=%s\n' "$$" "$rc" > "$STATE_DIR/${THREAD}.detach-status.tmp" 2>/dev/null \
      && mv -f "$STATE_DIR/${THREAD}.detach-status.tmp" "$STATE_DIR/${THREAD}.detach-status" 2>/dev/null \
      || true
  fi
  rm -f "$OUT_FILE" "$JSONL_FILE" "$LEASE_TMP"
  # Release a still-held acquisition mutex (exit paths inside the claim's
  # critical section — busy refusal, non-regular lease, lost ownership,
  # failed verify). A normal acquisition releases it inline first. The
  # helper is ownership-checked: a robbed acquirer leaves the new owner's
  # lock intact.
  release_lease_lock
  # Lease removal is ownership-checked: only the PID that wrote the lease may
  # remove it — a later overlapping dispatch's lease must never be deleted by
  # an earlier owner's exit.
  if [[ -f "$LEASE_FILE" && "$(cat "$LEASE_FILE" 2>/dev/null)" == "$$" ]]; then
    rm -f "$LEASE_FILE"
  fi
  # Detach hook: when a launcher exported a persisted-prompt tmpfile, this
  # (child) invocation owns it. NEVER remove a READY file — the parent owns it.
  if [[ -n "${CC_CODEX_PROMPT_TMPFILE:-}" ]]; then
    rm -f "$CC_CODEX_PROMPT_TMPFILE"
  fi
}
trap cleanup EXIT
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Preserve the raw Codex stream to a stable path before dying, so the path we
# point the user at still exists after the EXIT trap removes the temp file.
# Capped to the LAST 64 KB — the tail is where codex prints its actual error.
fail_with_diag() {
  local code="$1"; shift
  tail -c 65536 "$JSONL_FILE" > "$DIAG_FILE" 2>/dev/null || true
  printf '%s\n' "$@" >&2
  echo "Diagnostics saved to: $DIAG_FILE" >&2
  exit "$code"
}

# Build the codex flag array from CC_CODEX_FLAGS. Empty is fine — the
# `${arr[@]+...}` guard keeps `set -u` happy on bash 3.2 (macOS default),
# where expanding an empty array directly is an "unbound variable" error.
read -r -a EXTRA_FLAGS <<< "${CC_CODEX_FLAGS:-}"

# model/effort: initial/oneshot ONLY (kept stable across the thread; WARN if passed
# on resume). schema: a per-MESSAGE output shape — `codex exec resume` accepts
# --output-schema, so it applies on EVERY path (initial, oneshot, AND resume).
OVERRIDES=()
[[ -n "$MODEL"  ]] && OVERRIDES+=( -m "$MODEL" )
[[ -n "$EFFORT" ]] && OVERRIDES+=( -c "model_reasoning_effort=$EFFORT" )
SCHEMA_ARGS=()
[[ -n "$SCHEMA" ]] && SCHEMA_ARGS+=( --output-schema "$SCHEMA" )

# ── read prompt from stdin ────────────────────────────────────────────────
PROMPT="$(cat)"
[[ -z "$PROMPT" ]] && { echo "empty prompt on stdin" >&2; exit 1; }

# ── active lease ──────────────────────────────────────────────────────────
# In-flight marker for /cleanup: while this file names a live PID, the thread
# is mid-dispatch and must not be archived (a resume waiting inside
# `codex exec` writes nothing else until it returns). Acquired BEFORE any
# existing-thread mutation below (--new's sidecar reset, the invalid-ID
# discard): a busy thread must be refused with its state byte-for-byte
# intact. cleanup() removes the lease on exit only while this PID owns it.
#
# Acquisition is ATOMIC: an mkdir mutex (<thread>.active.lock — mkdir is
# atomic on POSIX) serializes the whole claim, so two near-simultaneous
# dispatches can never both pass the busy check and both write the lease
# (and a directory can no longer race into place between the check and the
# mv). Inside the mutex: the live-owner check, the non-regular-file refusal,
# and the tmp write + mv + verification. The winner publishes its PID into
# <lock>/owner with a noclobber (O_EXCL) write — an existing token means the
# directory was reclaimed from a stalled pre-token acquirer, which loses —
# and takeover is OWNERSHIP-gated: a lock with a LIVE recorded
# owner is never stolen regardless of age (an acquirer merely paused inside
# the critical section must not be robbed — age-only stealing reopened the
# exact double-dispatch race the mutex closes); a dead/invalid owner is
# reclaimed at once; an ownerless lock older than 60s (its acquirer crashed
# between mkdir and the token write) is reclaimed too. cleanup() releases a
# still-held mutex on every exit path.
if ! $ONESHOT; then
  if ! mkdir "$LEASE_LOCK" 2>/dev/null; then
    LOCK_OWNER="$(cat "$LEASE_LOCK/owner" 2>/dev/null || true)"
    if [[ "$LOCK_OWNER" =~ ^[1-9][0-9]{0,11}$ ]] && kill -0 "$LOCK_OWNER" 2>/dev/null; then
      # LIVE recorded owner: never steal, no matter how old the lock is.
      echo "thread $THREAD is busy (lease acquisition mutex $LEASE_LOCK is held by live pid=$LOCK_OWNER) — wait for it or use a different --thread" >&2
      exit 10
    fi
    STEAL=false
    if [[ -e "$LEASE_LOCK/owner" ]]; then
      STEAL=true   # owner recorded but dead (or token garbage): acquirer is gone
    else
      # Ownerless lock: only a crash between mkdir and the token write leaves
      # this state, and that window is a couple of builtins wide — an
      # ownerless lock older than 60s can only be a crashed acquirer.
      LOCK_MTIME="$(stat -f '%m' "$LEASE_LOCK" 2>/dev/null || stat -c '%Y' "$LEASE_LOCK" 2>/dev/null || true)"
      NOW_EPOCH="$(date +%s)"
      if [[ "$LOCK_MTIME" =~ ^[0-9]+$ ]] && (( NOW_EPOCH - LOCK_MTIME > 60 )); then
        STEAL=true
      fi
    fi
    if [[ "$STEAL" == true ]]; then
      rm -f "$LEASE_LOCK/owner" 2>/dev/null || true
      rmdir "$LEASE_LOCK" 2>/dev/null || true
    fi
    if ! mkdir "$LEASE_LOCK" 2>/dev/null; then
      echo "thread $THREAD is busy (concurrent lease acquisition holds $LEASE_LOCK) — retry shortly, or use a different --thread" >&2
      exit 10
    fi
  fi
  # Owner token: records WHO holds the mutex, so a paused-but-alive acquirer
  # is distinguishable from a crashed one and every release can be
  # ownership-checked. PUBLISHED WITH NOCLOBBER (set -C → open(O_EXCL)): the
  # write fails if a token already exists. An acquirer that won the mkdir but
  # stalled past the 60s ownerless-reclaim threshold resumes here to find the
  # reclaimer's token — it must LOSE, not overwrite (an unguarded write would
  # hand both processes a verified claim → double dispatch). A failed
  # publication means the directory is no longer ours: refuse WITHOUT touching
  # the existing token or the lock (HAVE_LEASE_LOCK is still false, so
  # cleanup() leaves both alone). The reclaim path above removed the
  # dead/absent owner file before its mkdir retry, so a legitimate winner
  # always finds an empty slot.
  if ! (set -C; printf '%s' "$$" > "$LEASE_LOCK/owner") 2>/dev/null; then
    echo "thread $THREAD is busy (lost $LEASE_LOCK to a concurrent reclaim before publishing ownership — now owned by pid=$(cat "$LEASE_LOCK/owner" 2>/dev/null)) — retry shortly, or use a different --thread" >&2
    exit 10
  fi
  HAVE_LEASE_LOCK=true
  # EXCLUSIVE acquisition: overwriting a live owner's lease would let the
  # faster of two overlapping dispatches remove the lease on exit (ownership
  # check passes for the overwriter) while the slower one still runs —
  # /cleanup would then see an idle thread mid-dispatch. It would also resume
  # the same codex session from two processes at once. Refuse instead; a
  # dead/malformed lease is stale state and is overwritten as before.
  if BUSY_PID="$(lease_busy_pid)"; then
    echo "thread $THREAD is busy (active dispatch pid=$BUSY_PID) — wait for it or use a different --thread" >&2
    exit 10   # cleanup() releases the mutex
  fi
  # A non-regular <thread>.active (e.g. a directory) can never hold a lease:
  # `mv` below would move the tmp file INSIDE it, and READY/dispatch would
  # proceed with no lease on disk. Refuse before writing anything.
  if [[ -e "$LEASE_FILE" && ! -f "$LEASE_FILE" ]]; then
    echo "cannot acquire the dispatch lease for thread '$THREAD': $LEASE_FILE exists but is not a regular file — inspect and remove it manually." >&2
    exit 10
  fi
  # Ownership re-verification, immediately before the lease write: an
  # acquirer that stalled long enough to be (wrongly or rightly) taken over
  # would otherwise resume here and double-dispatch. If the owner token no
  # longer names this PID the mutex is LOST — abort without writing .active;
  # the ownership-checked release leaves the new owner's lock intact.
  if [[ "$(cat "$LEASE_LOCK/owner" 2>/dev/null)" != "$$" ]]; then
    echo "thread $THREAD is busy (this acquisition lost $LEASE_LOCK to a stale-lock takeover mid-claim — now owned by pid=$(cat "$LEASE_LOCK/owner" 2>/dev/null)) — retry shortly, or use a different --thread" >&2
    exit 10   # cleanup()'s release is ownership-checked: the robber's lock survives
  fi
  printf '%s' "$$" > "$LEASE_TMP"
  mv -f "$LEASE_TMP" "$LEASE_FILE"
  # Verify the acquisition before releasing the mutex: races are excluded by
  # the lock, but the verification still catches filesystem-level surprises
  # (and any future caller that skips the mutex).
  if [[ ! -f "$LEASE_FILE" || "$(cat "$LEASE_FILE" 2>/dev/null)" != "$$" ]]; then
    echo "cannot acquire the dispatch lease for thread '$THREAD': $LEASE_FILE is not a regular file holding this PID after acquisition — inspect the state dir." >&2
    exit 10
  fi
  release_lease_lock
  # Detach child: canonical output boundary + status slate, established the
  # moment the lease is OURS — before ANY further preflight, so every later
  # warning (invalid saved .id discarded, ignored resume overrides, porcelain
  # guard notes) lands in the canonical sidecars instead of the launcher's
  # discarded pre-lease tmpfile. stdout and stderr are SPLIT: the reply echo
  # goes to <thread>.detach-output, warnings/errors to <thread>.detach-stderr
  # — so the watcher can deliver a successful run's warnings without
  # re-printing the reply. Both are truncated here, by the lease OWNER only
  # (a concurrent exit-10 loser never reaches this line). The stale status
  # record is removed BEFORE dispatch so the watcher can never read an old
  # verdict against this run's PID.
  if [[ -n "${CC_CODEX_READY_FILE:-}" ]]; then
    rm -f "$STATE_DIR/${THREAD}.detach-status"
    exec > "$STATE_DIR/${THREAD}.detach-output" 2> "$STATE_DIR/${THREAD}.detach-stderr"
    DETACH_CHILD=true
  fi
fi

# ── force-new ─────────────────────────────────────────────────────────────
if $FORCE_NEW; then
  # Reset the per-task sidecars too, so a reused thread name does not inherit
  # the previous task's findings ledger / scope / approval baseline. Runs
  # while HOLDING the lease — a busy thread was refused above with every
  # sidecar intact.
  rm -f "$ID_FILE" "$ROUNDS_FILE" "$FINDINGS_FILE" "$SCOPE_FILE" "$APPROVED_FILE" "$STATE_DIR/${THREAD}.topic"
fi

# Porcelain status with our own state dir filtered out — its .id/.log churn is
# not a "tracked-file mutation" and would otherwise false-positive the guard.
porcelain() {
  [[ -n "$REPO_ROOT" ]] || return 0
  # -uall lists untracked files individually; without it git collapses a new
  # untracked dir to "?? .claude/" and our own state writes leak past the filter.
  local out
  if ! out="$(git -C "$REPO_ROOT" status --porcelain -uall 2>/dev/null)"; then
    # A transient git failure (e.g. another process holding index.lock) must
    # not masquerade as an empty status — that would false-positive the guard
    # (fatal under CC_CODEX_TRIAGE_STRICT=1). Emit a sentinel; the guard skips
    # the comparison when either side carries it.
    echo "__PORCELAIN_UNAVAILABLE__"
    return 0
  fi
  printf '%s\n' "$out" | grep -vF '.claude/codex-threads/' || true
}

# ── tracked-file mutation guard (pre) ─────────────────────────────────────
REPO_ROOT="$(git -C . rev-parse --show-toplevel 2>/dev/null || true)"
PRE_PORCELAIN="$(porcelain)"

# ── code state at dispatch time (for the /autoreview gate) ────────────────
# This is the state Codex is about to look at. The Stop hook records it as the
# released fingerprint when this thread's verdict releases a cycle, instead of
# fingerprinting the worktree at turn-end: anything written between the verdict
# arriving and the turn ending was never reviewed, and stamping it as approved
# is how unreviewed code slips through a gate that is doing its job.
#
# Best-effort in every direction. --oneshot leaves no state at all; outside a
# repo, or with the fingerprint script missing, the file is simply absent and
# the hook falls back to its own fingerprint (the previous behaviour).
if ! $ONESHOT && [[ -n "$REPO_ROOT" && -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  _fp_sh="$CLAUDE_PLUGIN_ROOT/scripts/gate-fingerprint.sh"
  if [[ -f "$_fp_sh" ]]; then
    _fp="$( cd "$REPO_ROOT" && bash "$_fp_sh" 2>/dev/null || true )"
    if [[ -n "$_fp" ]]; then
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      printf '%s\n' "$_fp" > "$STATE_DIR/${THREAD}.dispatch-fp" 2>/dev/null || true
    fi
  fi
fi

# ── resolve thread ─────────────────────────────────────────────────────────
MODE=""
SID=""
if ! $ONESHOT && [[ -s "$ID_FILE" ]]; then
  SID="$(cat "$ID_FILE")"
  if ! [[ "$SID" =~ $UUID_RE ]]; then
    echo "WARN: saved session ID in $ID_FILE is not a valid UUID ('$SID'). Discarding and starting fresh." >&2
    rm -f "$ID_FILE"
    SID=""
  fi
fi

if $REQUIRE_EXISTING && [[ -z "$SID" ]]; then
  echo "No existing thread '$THREAD' (.claude/codex-threads/${THREAD}.id not found or invalid)." >&2
  echo "--require-existing refuses to create one. Start a thread first with /ask, /review, /plan, or /thread." >&2
  exit 6
fi

# ── detach handshake (child side) ─────────────────────────────────────────
# A --detach launcher exported CC_CODEX_READY_FILE and is polling it for our
# PID. Written only AFTER the lease is held (acquired above, before any
# thread-state mutation) and every preflight passed, so a DETACHED report
# proves /cleanup already sees this thread as in-use. The parent owns the
# READY file and removes it — NEVER delete it here.
if ! $ONESHOT && [[ -n "${CC_CODEX_READY_FILE:-}" ]]; then
  # (The canonical sidecar boundary + status slate were established right
  # after lease acquisition, above — here we only publish the PID.)
  printf '%s' "$$" > "$CC_CODEX_READY_FILE"
fi

# ── dispatch ──────────────────────────────────────────────────────────────
if $ONESHOT; then
  MODE="oneshot"
  # Throwaway: no thread tracking, no rollout persisted on the Codex side.
  # codex exec resume cannot continue an --ephemeral session — that is the point.
  CWD_FOR_CODEX="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  if ! codex exec --json --ephemeral -C "$CWD_FOR_CODEX" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        ${OVERRIDES[@]+"${OVERRIDES[@]}"} ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} \
        -o "$OUT_FILE" - <<< "$PROMPT" > "$JSONL_FILE" 2>&1; then
    fail_with_diag 3 "codex exec FAILED (oneshot)."
  fi
  # last-error means the LAST error: a successful dispatch clears the diag.
  rm -f "$DIAG_FILE"
elif [[ -n "$SID" ]]; then
  MODE="resume($SID)"
  # No model/effort overrides on resume: -s (sandbox) and -C (cwd) are fixed at
  # session creation and resume does not take them; -m/-c are accepted by newer
  # codex CLIs but we deliberately omit them to keep the thread's model/config
  # stable. --output-schema DOES apply here — it shapes this single message.
  if [[ -n "$MODEL$EFFORT" ]]; then
    echo "WARN: --model/--effort are ignored on resume (kept stable across the thread). Use --new to change them." >&2
  fi
  if ! codex exec resume --json "$SID" \
        ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} \
        -o "$OUT_FILE" - <<< "$PROMPT" > "$JSONL_FILE" 2>&1; then
    fail_with_diag 4 \
      "codex exec resume FAILED for thread '$THREAD' (session=$SID)." \
      "Possible causes: session expired/deleted, codex CLI upgrade broke wire format, or model unavailable." \
      "The saved UUID has NOT been cleared — re-run with --new to start a fresh thread (loses memory)."
  fi
  # last-error means the LAST error: a successful dispatch clears the diag.
  rm -f "$DIAG_FILE"
else
  MODE="initial"
  # Pin cwd via -C so initial dispatch isn't sensitive to who launches the script.
  CWD_FOR_CODEX="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  if ! codex exec --json -C "$CWD_FOR_CODEX" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
        ${OVERRIDES[@]+"${OVERRIDES[@]}"} ${SCHEMA_ARGS[@]+"${SCHEMA_ARGS[@]}"} \
        -o "$OUT_FILE" - <<< "$PROMPT" > "$JSONL_FILE" 2>&1; then
    fail_with_diag 3 "codex exec FAILED (initial)."
  fi
  # last-error means the LAST error: codex exited 0, so the previous failure's
  # diag is stale — remove it NOW, BEFORE UUID extraction, so the deliberate
  # diag write on a UUID-extraction failure below lands in a clean slot and is
  # never erased by its own dispatch.
  rm -f "$DIAG_FILE"
  # Extract the session UUID from the JSONL stream. First event carrying a
  # thread_id / session_id / conversation_id wins. Two-step: match the whole
  # key:value pair (whitespace-tolerant), then strip down to the value — no
  # fixed substr offsets, so a formatting change in codex --json output (e.g.
  # a space after the colon) cannot silently break thread persistence. The
  # strict UUID shape check happens below in bash ($UUID_RE).
  SID="$(awk '
    match($0, /"(thread_id|session_id|conversation_id)"[ \t]*:[ \t]*"[0-9a-fA-F-]+"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^.*"[ \t]*:[ \t]*"/, "", s)   # drop key, colon, opening quote
      sub(/"$/, "", s)                   # drop closing quote
      print s
      exit
    }
  ' "$JSONL_FILE")"
  if [[ -n "$SID" && "$SID" =~ $UUID_RE ]]; then
    echo "$SID" > "$ID_FILE"
  else
    echo "WARN: could not extract a valid UUID from codex --json output for thread '$THREAD' (got: '$SID')." >&2
    echo "The thread will NOT persist — next invocation will start fresh." >&2
    tail -c 65536 "$JSONL_FILE" > "$DIAG_FILE" 2>/dev/null || true
    echo "Raw stream saved to: $DIAG_FILE (file an issue if your codex CLI uses a non-standard event schema)." >&2
  fi
fi

# ── tracked-file mutation guard (post) ────────────────────────────────────
# Limitation: git status --porcelain only detects status TRANSITIONS. If a file
# was already dirty before the dispatch and Codex changes its content further,
# the porcelain line is unchanged and this guard will not fire. Commit/stash WIP
# or use CC_CODEX_FLAGS="-s read-only" for stronger protection.
STRICT_MUTATION_EXIT=false
if [[ -n "$REPO_ROOT" ]]; then
  POST_PORCELAIN="$(porcelain)"
  if [[ "$PRE_PORCELAIN" == *__PORCELAIN_UNAVAILABLE__* || "$POST_PORCELAIN" == *__PORCELAIN_UNAVAILABLE__* ]]; then
    echo "WARN: git status was unavailable for the mutation guard (pre or post) — skipping the comparison this round." >&2
  elif [[ "$PRE_PORCELAIN" != "$POST_PORCELAIN" ]]; then
    echo "WARN: tracked-file status changed during codex dispatch ($MODE)." >&2
    echo "Diff (pre vs post):" >&2
    diff <(echo "$PRE_PORCELAIN") <(echo "$POST_PORCELAIN") >&2 || true
    echo "Codex was likely run with a writable sandbox. Inspect the working tree before continuing." >&2
    # Exit 5 is deferred until AFTER the audit log append below — the one
    # exchange you most want in the log is the suspicious one.
    if [[ "${CC_CODEX_TRIAGE_STRICT:-0}" == "1" ]]; then STRICT_MUTATION_EXIT=true; fi
  fi
fi

# ── round counter + audit log (skipped for --oneshot, traceless) ──────────
if ! $ONESHOT; then
  # Round = number of successful dispatches on this PERSISTED thread. Skip the
  # bump when the thread failed to persist (no .id) — otherwise a never-resumed
  # thread accumulates rounds invisible to /thread-list, which iterates *.id.
  if [[ -s "$ID_FILE" ]]; then
    # Validate before arithmetic: a corrupted/CRLF .rounds would otherwise be
    # an arithmetic error under set -e — killing the script AFTER the paid
    # dispatch succeeded, losing the reply. Garbage resets the counter to 0.
    # Leading zeros count as garbage too: bash arithmetic parses 08 as invalid
    # octal — the exact trap the hook's is_num guards against.
    PREV_ROUNDS="$(cat "$ROUNDS_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$PREV_ROUNDS" =~ ^(0|[1-9][0-9]*)$ ]] || PREV_ROUNDS=0
    ROUND=$(( PREV_ROUNDS + 1 ))
    echo "$ROUND" > "$ROUNDS_FILE"
    # Topic label, written HERE and not before the dispatch: a failed run would
    # otherwise leave its label on a thread it never created, and the
    # never-overwrite rule would then pin that wrong label forever.
    # Written only when absent — it describes what the thread was CREATED for.
    # --new clears it with the rest of the thread's state.
    if [[ -n "$TOPIC" && ! -f "$STATE_DIR/${THREAD}.topic" ]]; then
      # Bash parameter expansion rather than `cut`: GNU cut terminates its
      # output with a newline and BSD cut does not, so building the line with
      # an external command produced a two-line file on Linux and a one-line
      # file on macOS. This is also one less process on a hot path.
      _tl="$(printf '%s' "$TOPIC" | tr -d '\n\r\t')"
      printf '%s\n' "${_tl:0:120}" > "$STATE_DIR/${THREAD}.topic" 2>/dev/null || true
    fi
  else
    ROUND=0
  fi

  # Rotate BEFORE appending so the newest entry always lands in the current
  # .log (a post-append rotation would move the just-written entry to .log.1
  # and leave /reply unable to find the last REPLY).
  LOG_CAP_BYTES="${CC_CODEX_TRIAGE_LOG_CAP_BYTES:-1048576}"
  # A non-numeric (or leading-zero octal-trap) override would error inside the
  # [[ -gt ]] below and silently disable rotation forever — fall back instead.
  [[ "$LOG_CAP_BYTES" =~ ^(0|[1-9][0-9]*)$ ]] || LOG_CAP_BYTES=1048576
  if [[ -f "$LOG_FILE" ]]; then
    LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
    if [[ -n "$LOG_SIZE" && "$LOG_SIZE" -gt "$LOG_CAP_BYTES" ]]; then
      mv -f "$LOG_FILE" "${LOG_FILE}.1"
    fi
  fi
  # Log format contract: the column-0 markers ([timestamp], PROMPT:, REPLY:,
  # ---) are load-bearing — the Stop hook's verdict parser uses them to read
  # verdicts from REPLY sections ONLY (a verdict literal inside a logged
  # PROMPT must never release the autoreview gate). Body lines are always
  # indented two spaces, so prompt/reply content cannot fake a marker.
  {
    echo "[$(date -u +%FT%TZ)] mode=$MODE thread=$THREAD round=$ROUND"
    echo "PROMPT:"; sed 's/^/  /' <<< "$PROMPT"
    echo "REPLY:"; sed 's/^/  /' "$OUT_FILE"
    echo "---"
  } >> "$LOG_FILE"
fi

if $STRICT_MUTATION_EXIT; then
  exit 5
fi

cat "$OUT_FILE"
