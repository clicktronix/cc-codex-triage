import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Reply, ReviewRow, Snapshot, ThreadRow } from '../types'
import { ago, cells, clip, elapsed, fit, fields, isStreamPath, lastEvent, lastReply, leasePid, plainReply, rounds, splitStateName } from './parse'
import type { Suffix } from './parse'

const PANE = 'codex-threads'
const PANE_COLUMNS = 48
const TICK_MS = 2000
const IDLE_EVERY = 8
const HOT_MS = 60_000
const DETAILED = 12
// Review states are never removed with their task, so the pane shows the latest few.
const REVIEWS = 5
// Each read is held to the engine's 4 MiB of process output.
const LOG_TAIL_BYTES = [65_536, 524_288, 4_194_304]

const snapshot = atom({ plugin: 'cc-codex-triage', key: 'snapshot' } as const, null, {
  shape: 'snapshot-5',
})
const reply = atom({ plugin: 'cc-codex-triage', key: 'reply' } as const, null, { shape: 'reply-2' })

type Files = Map<string, Map<Suffix, number>>

async function readRaw($: EngineInterface, path: string): Promise<string> {
  try {
    return await $.fs.read(path)
  } catch {
    return ''
  }
}

async function readText($: EngineInterface, path: string): Promise<string> {
  return (await readRaw($, path)).trim()
}

// The lease as the driver and thread-index.sh read it: `$(cat)` drops trailing
// newlines and nothing else, so leasePid sees any other whitespace and refuses it.
async function livePid($: EngineInterface, dir: string, name: string): Promise<string | null> {
  const pid = leasePid((await readRaw($, `${dir}/${name}.active`)).replace(/\n+$/, ''))
  return pid && (await isAlive($, pid)) ? pid : null
}

async function isAlive($: EngineInterface, pid: string): Promise<boolean> {
  const { exitCode } = await $.process.run(['kill', '-0', pid], { timeoutMs: 5000 })
  return exitCode === 0
}

async function streamEvent($: EngineInterface, dir: string, thread: string, pid: string) {
  const pointer = fields(await readText($, `${dir}/${thread}.stream`))
  if (pointer.pid !== pid || !pointer.path || !isStreamPath(thread, pointer.path)) return null
  const stat = await $.fs.stat(pointer.path).catch(() => null)
  if (stat?.kind !== 'file' || stat.isLink) return null
  const tail = await $.process.run(['tail', '-c', '32768', pointer.path], { timeoutMs: 5000 })
  const event = tail.exitCode === 0 ? lastEvent(tail.stdout) : null
  if (!event) return null
  const redacted = await $.process.run(['bash', `${$.plugin.root}/scripts/redact.sh`], {
    stdin: event,
    timeoutMs: 5000,
  })
  return redacted.exitCode === 0 ? clip(redacted.stdout.trim(), 120) : null
}

function lastActivityMs(files: Map<Suffix, number>): number {
  return files.get('log') ?? files.get('id') ?? files.get('active') ?? 0
}

async function threadRow(
  $: EngineInterface,
  dir: string,
  name: string,
  files: Map<Suffix, number>,
  pid: string | null,
) {
  const row: ThreadRow = {
    name,
    topic: (await readText($, `${dir}/${name}.topic`)).split('\n')[0] ?? '',
    rounds: Number((await readText($, `${dir}/${name}.rounds`)).replace(/\D/g, '')) || 0,
    lastActivityMs: lastActivityMs(files),
    isBusy: false,
    pid,
    startedAtMs: null,
    event: null,
    preview: null,
    moreLines: 0,
  }
  if (!pid) {
    const lines = (await replyFor($, dir, name, row.lastActivityMs))?.lines ?? []
    const first = lines.findIndex(line => line.trim())
    return first === -1 ? row : { ...row, preview: lines[first] ?? null, moreLines: lines.length - first - 1 }
  }

  return {
    ...row,
    isBusy: true,
    startedAtMs: files.get('active') ?? null,
    event: await streamEvent($, dir, name, pid),
  }
}

// `pinned` is the thread whose reply is open: it stays listed past the row cap.
async function scan($: EngineInterface, dir: string | null, atMs: number, pinned: string | null): Promise<Snapshot> {
  const empty: Snapshot = { atMs, stateDir: dir, threads: [], reviews: [], error: null }
  if (!dir || !(await $.fs.exists(dir))) return empty

  const files: Files = new Map()
  for (const entry of await $.fs.list(dir)) {
    const parsed = entry.kind === 'file' ? splitStateName(entry.name) : null
    if (!parsed) continue
    const own = files.get(parsed.thread) ?? new Map<Suffix, number>()
    own.set(parsed.suffix, entry.mtimeMs)
    files.set(parsed.thread, own)
  }

  // Liveness before the row cap: stale leases a SIGKILL left behind must not
  // crowd a live dispatch out of the list.
  const live = new Map<string, string>()
  await Promise.all(
    [...files]
      .filter(([, own]) => own.has('active'))
      .map(async ([name]) => {
        const pid = await livePid($, dir, name)
        if (pid) live.set(name, pid)
      }),
  )
  const recent = [...files]
    // A first dispatch has a lease but no .id until it completes.
    .filter(([name, own]) => own.has('id') || live.has(name))
    .sort(([an, a], [bn, b]) => Number(live.has(bn)) - Number(live.has(an)) || lastActivityMs(b) - lastActivityMs(a))
    .filter(([name], i) => i < DETAILED || name === pinned)
  const threads = await Promise.all(
    recent.map(([name, own]) => threadRow($, dir, name, own, live.get(name) ?? null)),
  )

  const reviews: ReviewRow[] = []
  for (const [name, own] of files) {
    if (!own.has('review-state')) continue
    const state = fields(await readText($, `${dir}/${name}.review-state`))
    reviews.push({
      name,
      status: state.status ?? '?',
      round: state.round ? Number(state.round) : null,
      verdict: state.verdict ?? '-',
      isGateEligible: state.gate_eligible === 'true',
      head: state.head || null,
      atMs: Date.parse(state.timestamp ?? '') || own.get('review-state') || 0,
    })
  }
  reviews.sort((a, b) => b.atMs - a.atMs)

  return { ...empty, threads: threads.sort((a, b) => Number(b.isBusy) - Number(a.isBusy)), reviews }
}

// The log's end, widened until it holds the latest whole REPLY section: a long reply
// outgrows a short tail, and a whole log may outgrow one engine read. A tail shorter than
// the file drops its first line, which may begin mid-line and so look like a marker.
// Every shown line passes through redact.sh. Null is a read that failed and may be tried again.
async function loadReply($: EngineInterface, dir: string, thread: string, forMs: number): Promise<Reply | null> {
  const ready: Reply = { thread, forMs, status: 'ready', lines: null }
  const path = `${dir}/${thread}.log`
  try {
    const stat = await $.fs.stat(path)
    if (stat.kind !== 'file' || stat.isLink) return ready
    for (const bytes of LOG_TAIL_BYTES) {
      const tail = await $.process.run(['tail', '-c', String(bytes), path], { timeoutMs: 5000 })
      if (tail.exitCode !== 0) return null
      const isWhole = stat.size <= bytes
      const text = lastReply(isWhole ? tail.stdout : tail.stdout.slice(tail.stdout.indexOf('\n') + 1))
      if (text === null && !isWhole) continue
      if (!text) return ready
      const redacted = await $.process.run(['bash', `${$.plugin.root}/scripts/redact.sh`], {
        stdin: text,
        timeoutMs: 5000,
      })
      return redacted.exitCode === 0
        ? { ...ready, lines: plainReply(redacted.stdout.replace(/\s+$/, '').split('\n')) }
        : null
    }
    return ready
  } catch {
    return null
  }
}

// Each log is read again only when it changes, so a pane redrawn every tick costs no
// reads; a failed read is not kept, so the next scan or press tries again.
const replies = new Map<string, Reply>()

async function replyFor($: EngineInterface, dir: string, thread: string, forMs: number): Promise<Reply | null> {
  const cached = replies.get(`${dir}/${thread}`)
  if (cached?.forMs === forMs) return cached
  const loaded = await loadReply($, dir, thread, forMs)
  if (loaded) replies.set(`${dir}/${thread}`, loaded)
  return loaded
}

// A load lands only on the selection it was started for: a press on another thread, a
// collapse or a newer round made while it ran wins over it.
async function showReply($: EngineInterface, dir: string, thread: string, forMs: number) {
  const loaded = await replyFor($, dir, thread, forMs)
  await update($, reply, open =>
    open?.thread === thread && open.forMs === forMs
      ? { thread, forMs, status: loaded ? ('ready' as const) : ('failed' as const), lines: loaded ? loaded.lines : open.lines }
      : open,
  )
}

// The driver's thread grammar; a name outside it never reaches a path.
const THREAD_NAME = /^[A-Za-z0-9_.-]+$/

async function toggleReply($: EngineInterface, thread: string): Promise<'opened' | 'closed' | 'missing'> {
  const shot = await read($, snapshot)
  const row = shot?.threads.find(t => t.name === thread)
  if (!shot?.stateDir) return 'missing'
  if (!row) {
    // Past the row cap: open it by its state files; the next scan pins it and loads the reply.
    if (!THREAD_NAME.test(thread) || !(await $.fs.exists(`${shot.stateDir}/${thread}.id`))) return 'missing'
    await update($, reply, () => ({ thread, forMs: -1, status: 'loading' as const, lines: null }))
    return 'opened'
  }
  let isOpening = false
  await update($, reply, open => {
    isOpening = open?.thread !== thread
    return isOpening ? { thread, forMs: row.lastActivityMs, status: 'loading' as const, lines: null } : null
  })
  if (isOpening) await showReply($, shot.stateDir, thread, row.lastActivityMs)
  return isOpening ? 'opened' : 'closed'
}

// An open reply follows its thread: a new round or a failed read loads it again, and a
// thread gone closes it.
// `pinned` is the thread the scan behind `shot` kept listed. A scan started before a newer
// pick never saw it, so it neither closes nor loads that pick; the next scan does.
async function followReply($: EngineInterface, shot: Snapshot, pinned: string | null) {
  const open = await read($, reply)
  if (!open) return
  const row = shot.threads.find(t => t.name === open.thread)
  if (!row || !shot.stateDir) {
    if (open.thread !== pinned) return
    await update($, reply, now => (now?.thread === open.thread ? null : now))
    return
  }
  if (row.lastActivityMs === open.forMs && open.status !== 'failed') return
  const forMs = row.lastActivityMs
  await update($, reply, now => (now?.thread === open.thread ? { ...now, forMs, status: 'loading' as const } : now))
  await showReply($, shot.stateDir, open.thread, forMs)
}

// An approval belongs to one commit, so the row names it: the reader compares it with their HEAD.
function reviewLine(r: ReviewRow): string {
  const status = r.status === 'APPROVED' && r.head ? `APPROVED ${r.head.slice(0, 7)}` : r.status
  return `${r.name} · ${status} · ${r.verdict}${r.isGateEligible ? ' · gate' : ''}`
}

function finishedLine(before: ThreadRow, thread: ThreadRow | undefined, reviews: ReviewRow[], succeeded: boolean): string {
  // Reading or redacting a preview can fail even after the driver saved its round.
  if (!thread || thread.rounds <= before.rounds || (!succeeded && thread.lastActivityMs === before.lastActivityMs)) {
    return `Codex ${before.name}: dispatch ended without a confirmed round`
  }
  const review = reviews.find(r => r.name === thread.name && r.round === thread.rounds)
  const verdict = review && ['APPROVED', 'REQUEST_CHANGES', 'CAP_REACHED'].includes(review.status) && ['APPROVE', 'REQUEST_CHANGES'].includes(review.verdict) ? ` · ${review.verdict}` : ''
  return `Codex ${thread.name}: round ${thread.rounds} finished${verdict}`
}

let stateDir: { cwd: string; dir: string | null } | null = null
let hotUntilMs = 0
let ticks = 0
let scanning: Promise<void> | null = null
let timer: { cancel: () => void } | null = null

async function resolveStateDir($: EngineInterface, refresh: boolean): Promise<string | null> {
  const cwd = await $.session.cwd()
  if (!refresh && stateDir?.cwd === cwd) return stateDir.dir
  const run = await $.process.run(['bash', `${$.plugin.root}/scripts/state-dir.sh`, '--read-only'], {
    cwd,
    env: { CLAUDE_PROJECT_DIR: cwd },
    timeoutMs: 10_000,
  })
  if (run.exitCode !== 0 || !run.stdout.trim()) {
    stateDir = null
    throw new Error(run.stderr.trim() || 'Could not resolve the thread directory')
  }
  stateDir = { cwd, dir: run.stdout.trim() }
  return stateDir.dir
}

// Idle, the scan runs every IDLE_EVERY ticks; it runs every tick while a thread
// is busy, while the pane is shown, or for HOT_MS after a cc-codex-triage call.
// One scan at a time. A forced tick waits for the one in flight and then scans itself, so a
// command sees what it just picked rather than what an earlier scan started from.
async function tick($: EngineInterface, isForced = false) {
  while (scanning) {
    if (!isForced) return
    await scanning
  }
  scanning = runTick($, isForced).finally(() => {
    scanning = null
  })
  await scanning
}

async function runTick($: EngineInterface, isForced: boolean) {
  ticks += 1
  const now = await $.clock.now()
  const previous = await read($, snapshot)
  const isBusy = previous?.threads.some(t => t.isBusy) ?? false
  const isShown = (await $.ui.panes()).some(p => p.id === PANE && p.isShown)
  if (!isForced && !isBusy && !isShown && now > hotUntilMs && ticks % IDLE_EVERY !== 0) return

  const pinned = (await read($, reply))?.thread ?? null
  let next: Snapshot
  try {
    next = await scan($, await resolveStateDir($, isForced), now, pinned)
  } catch (error) {
    // A failed scan says nothing about the threads: keep what was last seen, so
    // a running dispatch is neither dropped nor announced as finished.
    const kept = previous ?? { atMs: now, stateDir: stateDir?.dir ?? null, threads: [], reviews: [], error: null }
    await update($, snapshot, () => ({ ...kept, error: String(error) }))
    return
  }
  for (const before of previous?.threads ?? []) {
    if (previous?.stateDir !== next.stateDir || !before.isBusy) continue
    const after = next.threads.find(t => t.name === before.name)
    if (after?.isBusy && after.pid === before.pid && after.startedAtMs === before.startedAtMs) {
      // The worker appends its result before it drops its lease. Keep the
      // starting round through this window, including for the live band.
      after.rounds = before.rounds
      after.lastActivityMs = before.lastActivityMs
    } else if (!after?.isBusy) {
      const status = fields(await readText($, `${next.stateDir}/${before.name}.detach-status`))
      const rc = status.pid === before.pid ? status.rc : undefined
      const message = rc && rc !== '0' ? `Codex ${before.name}: dispatch exited ${rc}` : finishedLine(before, after, next.reviews, rc === '0')
      $.ui.toast(message, { timeoutMs: 8000 })
    }
  }
  await update($, snapshot, () => next)
  await followReply($, next, pinned)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'codex-pane',
      description: "Show this context's Codex threads in a pane; with a thread name, its whole last reply",
      argumentHint: '[thread]',
    })
    timer?.cancel()
    timer = $.clock.every(TICK_MS, () => void tick($))
    void tick($, true)

    return next(e)
  })

  // A thread name opens its reply without a press: above the prompt on the main screen the
  // pane's buttons take no clicks and ctrl+x tab does not reach them.
  on('command.run', { command: 'codex-pane' }, async ($, e) => {
    const thread = e.args.trim()
    const isOpen = (await $.ui.panes()).some(p => p.id === PANE)
    if (!thread && isOpen) {
      await $.ui.close({ id: PANE })
      return { text: 'Codex threads pane closed.' }
    }
    if (!isOpen) await $.ui.open({ id: PANE, title: 'Codex', columns: PANE_COLUMNS })
    await tick($, true)
    if (!thread) return { text: 'Codex threads pane opened.' }

    const result = await toggleReply($, thread)
    if (result === 'missing') return { text: `No Codex thread named ${clip(thread, 64)} in this context.` }
    if (result === 'closed') return { text: `Closed the reply view for ${thread}.` }
    await tick($, true)
    // Above the prompt the block shows a window of the list; bring the opened thread into it.
    // A refused or failed scroll leaves the reply open where it is.
    await $.ui.scroll({ to: { key: `thread:${thread}` }, in: PANE, block: 'start' }).catch(() => undefined)

    return { text: `Opened the reply view for ${thread}.` }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    // Open the fast window before the call runs: a foreground dispatch holds this
    // call for its whole length, and its lease lives only inside it.
    const isTriage = e.command.includes('cc-codex-triage')
    if (isTriage) {
      hotUntilMs = (await $.clock.now()) + HOT_MS
      void tick($, true)
    }
    const ran = await next(e)
    if (isTriage) {
      hotUntilMs = (await $.clock.now()) + HOT_MS
      void tick($, true)
    }

    return ran
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const busy = (await read($, snapshot))?.threads.filter(t => t.isBusy) ?? []
    const first = busy[0]
    if (!first || e.props.hasSurvey) return next(e)

    const { Box, Text } = $.ui.resolve(e)
    const now = await $.clock.now()
    const more = busy.length > 1 ? ` (+${busy.length - 1})` : ''

    return (
      <Box>
        <Text color="cyan">Codex</Text>
        <Text dimColor>
          {' '}· {first.name}{more} · round {first.rounds + 1} · {elapsed(now - (first.startedAtMs ?? now))}
          {first.event ? ` · ${first.event}` : ''}
        </Text>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const shot = await read($, snapshot)
    const open = await read($, reply)
    const now = await $.clock.now()
    const width = Math.max(20, e.props.bodyColumns)
    const cut = (text: string) => fit(text, width)
    // A reply worth opening: more lines than the preview, or a first line the pane cuts.
    const isExpandable = (t: ThreadRow) => t.moreLines > 0 || cells(`  ${t.preview ?? ''}`) > width
    const preview = (t: ThreadRow) => {
      const more = t.moreLines > 0 ? ` · +${t.moreLines} lines` : ''
      return `${fit(`  ${t.preview ?? ''}`, width - cells(more))}${more}`
    }

    if (!shot) return <Text dimColor>Reading Codex threads…</Text>

    return (
      <Box flexDirection="column">
        {shot.error && <Text color="red">{cut(`Last scan failed: ${shot.error}`)}</Text>}
        {shot.threads.length === 0 && <Text dimColor>No Codex threads in this context.</Text>}
        {shot.threads.map(t => (
          <Box flexDirection="column">
            {(() => {
              const header = (
                <Text color={t.isBusy ? 'cyan' : undefined} dimColor={!t.isBusy}>
                  {cut(
                    t.isBusy
                      ? `● ${t.name} · round ${t.rounds + 1} · ${elapsed(now - (t.startedAtMs ?? now))}`
                      : `○ ${t.name} · ${rounds(t.rounds)} · ${ago(now - t.lastActivityMs)}`,
                  )}
                </Text>
              )
              // A busy thread opens its previous round's reply; an idle one only when there is more to see.
              return t.isBusy || isExpandable(t) || open?.thread === t.name ? (
                <Button key={`thread:${t.name}`} plain onPress={() => void toggleReply($, t.name)}>
                  {header}
                </Button>
              ) : (
                header
              )
            })()}
            {t.isBusy && t.event && <Text>{cut(`  ${t.event}`)}</Text>}
            {t.topic && <Text dimColor>{cut(`  ${t.topic}`)}</Text>}
            {open?.thread === t.name ? (
              <Box flexDirection="column" marginLeft={2} marginBottom={1}>
                {open.status === 'loading' && !open.lines && <Text dimColor>Reading the reply…</Text>}
                {open.status === 'failed' && <Text dimColor>{cut('Could not read the reply; trying again')}</Text>}
                {open.status === 'ready' && !open.lines && (
                  <Text dimColor>{cut(`No saved reply to show; see ${t.name}.log`)}</Text>
                )}
                {open.lines?.map(line => <Text>{line || ' '}</Text>)}
              </Box>
            ) : (
              t.preview &&
              (isExpandable(t) ? (
                <Button key={`reply:${t.name}`} plain onPress={() => void toggleReply($, t.name)}>
                  <Text>{preview(t)}</Text>
                </Button>
              ) : (
                <Text>{preview(t)}</Text>
              ))
            )}
          </Box>
        ))}
        {!open && shot.threads.some(isExpandable) && <Text dimColor>{cut(e.props.placement === 'dock' ? '/codex-pane <thread> or a click: whole reply' : '/codex-pane <thread>: whole reply')}</Text>}
        {shot.reviews.length > 0 && (
          <Box flexDirection="column" marginTop={1}>
            <Text weight="semibold">Required review</Text>
            {shot.reviews.slice(0, REVIEWS).map(r => (
              <Text color={r.status === 'APPROVED' ? 'green' : r.status === 'CAP_REACHED' ? 'red' : undefined}>
                {cut(reviewLine(r))}
              </Text>
            ))}
            {shot.reviews.length > REVIEWS && <Text dimColor>{cut(`+${shot.reviews.length - REVIEWS} older`)}</Text>}
          </Box>
        )}
      </Box>
    )
  })
}
