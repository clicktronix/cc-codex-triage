import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Reply, ReviewRow, Snapshot, ThreadRow } from '../types'
import { ago, clip, elapsed, fields, isStreamPath, lastEvent, lastReply, leasePid, rounds, splitStateName } from './parse'
import type { Suffix } from './parse'

const PANE = 'codex-threads'
const PANE_COLUMNS = 48
const TICK_MS = 2000
const IDLE_EVERY = 8
const HOT_MS = 60_000
const DETAILED = 12
// Each read is held to the engine's 4 MiB of process output.
const LOG_TAIL_BYTES = [65_536, 524_288, 4_194_304]

const snapshot = atom({ plugin: 'cc-codex-triage', key: 'snapshot' } as const, null, {
  shape: 'snapshot-2',
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
  return files.get('log') ?? files.get('id') ?? 0
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
    startedAtMs: null,
    event: null,
    preview: null,
  }
  if (!pid) {
    const lines = (await replyFor($, dir, name, row.lastActivityMs))?.lines ?? []
    return { ...row, preview: lines.find(line => line.trim()) ?? null }
  }

  return {
    ...row,
    isBusy: true,
    startedAtMs: files.get('active') ?? null,
    event: await streamEvent($, dir, name, pid),
  }
}

async function scan($: EngineInterface, dir: string | null, atMs: number): Promise<Snapshot> {
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
    .slice(0, DETAILED)
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
      verdict: state.verdict ?? '-',
      isGateEligible: state.gate_eligible === 'true',
    })
  }

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
      return redacted.exitCode === 0 ? { ...ready, lines: redacted.stdout.replace(/\s+$/, '').split('\n') } : null
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

async function toggleReply($: EngineInterface, thread: string) {
  const shot = await read($, snapshot)
  const row = shot?.threads.find(t => t.name === thread)
  if (!shot?.stateDir || !row) return
  let isOpening = false
  await update($, reply, open => {
    isOpening = open?.thread !== thread
    return isOpening ? { thread, forMs: row.lastActivityMs, status: 'loading' as const, lines: null } : null
  })
  if (isOpening) await showReply($, shot.stateDir, thread, row.lastActivityMs)
}

// An open reply follows its thread: a new round or a failed read loads it again, and a
// thread gone closes it.
async function followReply($: EngineInterface, shot: Snapshot) {
  const open = await read($, reply)
  if (!open) return
  const row = shot.threads.find(t => t.name === open.thread)
  if (!row || !shot.stateDir) {
    await update($, reply, now => (now?.thread === open.thread ? null : now))
    return
  }
  if (row.lastActivityMs === open.forMs && open.status !== 'failed') return
  const forMs = row.lastActivityMs
  await update($, reply, now => (now?.thread === open.thread ? { ...now, forMs, status: 'loading' as const } : now))
  await showReply($, shot.stateDir, open.thread, forMs)
}

function finishedLine(name: string, thread: ThreadRow | undefined, reviews: ReviewRow[]): string {
  // A first dispatch that fails leaves no .id, so its thread drops out of the scan.
  if (!thread) return `Codex ${name}: dispatch ended without a saved round`
  const review = reviews.find(r => r.name === thread.name)
  const verdict = review && review.verdict !== '-' ? ` · ${review.verdict}` : ''
  return `Codex ${thread.name}: round ${thread.rounds} finished${verdict}`
}

let stateDir: { cwd: string; dir: string | null } | null = null
let hotUntilMs = 0
let ticks = 0
let isScanning = false
let timer: { cancel: () => void } | null = null

async function resolveStateDir($: EngineInterface): Promise<string | null> {
  const cwd = await $.session.cwd()
  if (stateDir?.cwd === cwd) return stateDir.dir
  const run = await $.process.run(['bash', `${$.plugin.root}/scripts/state-dir.sh`, '--read-only'], {
    cwd,
    env: { CLAUDE_PROJECT_DIR: cwd },
    timeoutMs: 10_000,
  })
  stateDir = { cwd, dir: run.exitCode === 0 ? run.stdout.trim() || null : null }
  return stateDir.dir
}

// Idle, the scan runs every IDLE_EVERY ticks; it runs every tick while a thread
// is busy, while the pane is shown, or for HOT_MS after a cc-codex-triage call.
async function tick($: EngineInterface, isForced = false) {
  if (isScanning) return
  isScanning = true
  try {
    ticks += 1
    const now = await $.clock.now()
    const previous = await read($, snapshot)
    const isBusy = previous?.threads.some(t => t.isBusy) ?? false
    const isShown = (await $.ui.panes()).some(p => p.id === PANE && p.isShown)
    if (!isForced && !isBusy && !isShown && now > hotUntilMs && ticks % IDLE_EVERY !== 0) return

    let next: Snapshot
    try {
      next = await scan($, await resolveStateDir($), now)
    } catch (error) {
      // A failed scan says nothing about the threads: keep what was last seen, so
      // a running dispatch is neither dropped nor announced as finished.
      const kept = previous ?? { atMs: now, stateDir: stateDir?.dir ?? null, threads: [], reviews: [], error: null }
      await update($, snapshot, () => ({ ...kept, error: String(error) }))
      return
    }
    for (const before of previous?.threads ?? []) {
      const after = next.threads.find(t => t.name === before.name)
      if (before.isBusy && !after?.isBusy) $.ui.toast(finishedLine(before.name, after, next.reviews), { timeoutMs: 8000 })
    }
    await update($, snapshot, () => next)
    await followReply($, next)
  } finally {
    isScanning = false
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'codex-pane',
      description: "Show this context's Codex threads in a pane",
    })
    timer?.cancel()
    timer = $.clock.every(TICK_MS, () => void tick($))
    void tick($, true)

    return next(e)
  })

  on('command.run', { command: 'codex-pane' }, async $ => {
    const isOpen = (await $.ui.panes()).some(p => p.id === PANE)
    if (isOpen) {
      await $.ui.close({ id: PANE })
      return { text: 'Codex threads pane closed.' }
    }
    await $.ui.open({ id: PANE, title: 'Codex', columns: PANE_COLUMNS })
    await tick($, true)

    return { text: 'Codex threads pane opened.' }
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
    const cut = (text: string) => (text.length > width ? `${text.slice(0, width - 1)}…` : text)

    if (!shot) return <Text dimColor>Reading Codex threads…</Text>

    return (
      <Box flexDirection="column">
        {shot.error && <Text color="red">{cut(`Last scan failed: ${shot.error}`)}</Text>}
        {shot.threads.length === 0 && <Text dimColor>No Codex threads in this context.</Text>}
        {shot.threads.map(t => (
          <Box flexDirection="column">
            <Button key={`thread:${t.name}`} plain onPress={() => void toggleReply($, t.name)}>
              <Text color={t.isBusy ? 'cyan' : undefined} dimColor={!t.isBusy}>
                {cut(
                  t.isBusy
                    ? `● ${t.name} · round ${t.rounds + 1} · ${elapsed(now - (t.startedAtMs ?? now))}`
                    : `○ ${t.name} · ${rounds(t.rounds)} · ${ago(now - t.lastActivityMs)}`,
                )}
              </Text>
            </Button>
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
              t.preview && (
                <Button key={`reply:${t.name}`} plain onPress={() => void toggleReply($, t.name)}>
                  <Text wrap="truncate-end">  {t.preview}</Text>
                </Button>
              )
            )}
          </Box>
        ))}
        {shot.threads.length > 0 && !open && <Text dimColor>{cut('ctrl+x tab, then Enter: whole reply')}</Text>}
        {shot.reviews.length > 0 && (
          <Box flexDirection="column" marginTop={1}>
            <Text weight="semibold">Required review</Text>
            {shot.reviews.map(r => (
              <Text color={r.status === 'APPROVED' ? 'green' : r.status === 'CAP_REACHED' ? 'red' : undefined}>
                {cut(`${r.name} · ${r.status} · ${r.verdict}${r.isGateEligible ? ' · gate' : ''}`)}
              </Text>
            ))}
          </Box>
        )}
      </Box>
    )
  })
}
