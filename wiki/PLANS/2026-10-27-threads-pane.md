# Codex threads pane

Goal: in the Claude Code CLI, show the current context's Codex threads beside the
transcript without a model turn: which thread is dispatching, its round, how long it has
run, what Codex is doing now, and the required-review state. While a dispatch runs, a
one-line band above the prompt says the same. Ships inside the cc-codex-triage plugin as
a TypeScript mod (Claude Code 2.1.287+).

## Milestones

1. [x] **The driver publishes its live event stream.** `codex-thread.sh` writes
   `<thread>.stream` (`pid=`, `path=` of the `codex exec --json` file) once the lease is
   held, and removes it under the same ownership check as the lease. First, because the
   stream lives under a random `mktemp` name: nothing outside the driver can find what
   Codex is doing now, and every other field the pane shows is already on disk.
2. [x] **The mod reads state itself.** `hooks/register.tsx` lists the state directory
   through `$.fs`, resolves it once per working directory with `state-dir.sh`, checks a
   lease PID with `kill -0` under the driver's lease grammar (`parse.ts`), tails the
   stream and passes the event line through `redact.sh`. Chosen over a snapshot script so
   the whole feature is one TypeScript module; the cost is the lease grammar written in TS
   beside `thread-index.sh`. A thread with a live lease is listed before it has an `.id`,
   since a first dispatch writes `.id` only when it completes.
3. [x] **Pane, band, toast.** `/codex-pane` toggles the pane; the `AbovePrompt` band shows
   while a lease is live; a toast reports a finished round. Scans run every 2 s while busy,
   shown, or for 60 s after a Bash call naming cc-codex-triage, every 16 s otherwise.
4. [x] **Tests.** Driver regression for `.stream` (written with the lease, removed after
   success and failure, absent on a refused dispatch; fails on the old driver).
   `hooks/register.test.tsx` under `claude plugin test`; two guards mutation-checked.
   `tests/run.sh` runs `claude plugin validate --strict` and `claude plugin test`; CI
   installs Claude Code 2.1.310 for them.
5. [x] **Docs and live check.** Plugin README section; a live detached dispatch in a real
   terminal session (tmux) showed the pane row, the live event, the band and the toast.

## Findings

- TypeScript 5.6 stops on the depth of the engine's types (TS2589); 5.9.3 checks clean.
- Claude Code 2.1.150 rejects a `hooks.json` without a `hooks` record, so it carries
  `"hooks": {}` beside `modules`; 2.1.150 then validates the plugin.
- Claude Code 2.1.251 (mods behind an early-access flag) rejects the module, which hooks
  events added later; without that flag the module is not loaded.
