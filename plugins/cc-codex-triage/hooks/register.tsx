import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { ReviewRow, Snapshot, ThreadRow } from '../types'
import { ago, elapsed, fields, lastEvent, leasePid, rounds, splitStateName } from './parse'
import type { Suffix } from './parse'

const PANE = 'codex-threads'
const TICK_MS = 2000
const IDLE_EVERY = 8
const HOT_MS = 60_000
const DETAILED = 12

const snapshot = atom({ plugin: 'cc-codex-triage', key: 'snapshot' } as const, null, {
  shape: 'snapshot-1',
})

type Files = Map<string, Map<Suffix, number>>

async function readText($: EngineInterface, path: string): Promise<string> {
  try {
    return (await $.fs.read(path)).trim()
  } catch {
    return ''
  }
}

async function isAlive($: EngineInterface, pid: string): Promise<boolean> {
  const { exitCode } = await $.process.run(['kill', '-0', pid], { timeoutMs: 5000 })
  return exitCode === 0
}

async function streamEvent($: EngineInterface, dir: string, thread: string, pid: string) {
  const pointer = fields(await readText($, `${dir}/${thread}.stream`))
  if (pointer.pid !== pid || !pointer.path) return null
  const tail = await $.process.run(['tail', '-c', '32768', pointer.path], { timeoutMs: 5000 })
  const event = tail.exitCode === 0 ? lastEvent(tail.stdout) : null
  if (!event) return null
  const redacted = await $.process.run(['bash', `${$.plugin.root}/scripts/redact.sh`], {
    stdin: event,
    timeoutMs: 5000,
  })
  return redacted.exitCode === 0 ? redacted.stdout.trim() : null
}

async function threadRow($: EngineInterface, dir: string, name: string, files: Map<Suffix, number>) {
  const lastActivityMs = files.get('log') ?? files.get('id') ?? 0
  const row: ThreadRow = {
    name,
    topic: (await readText($, `${dir}/${name}.topic`)).split('\n')[0] ?? '',
    rounds: Number((await readText($, `${dir}/${name}.rounds`)).replace(/\D/g, '')) || 0,
    lastActivityMs,
    isBusy: false,
    startedAtMs: null,
    event: null,
  }
  if (!files.has('active')) return row
  const pid = leasePid(await readText($, `${dir}/${name}.active`))
  if (!pid || !(await isAlive($, pid))) return row

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

  const recent = [...files]
    // A first dispatch has a lease but no .id until it completes.
    .filter(([, own]) => own.has('id') || own.has('active'))
    .sort(([, a], [, b]) => Number(b.has('active')) - Number(a.has('active')) || (b.get('log') ?? 0) - (a.get('log') ?? 0))
    .slice(0, DETAILED)
  const threads = await Promise.all(recent.map(([name, own]) => threadRow($, dir, name, own)))

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

function finishedLine(thread: ThreadRow, reviews: ReviewRow[]): string {
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
      next = { atMs: now, stateDir: stateDir?.dir ?? null, threads: [], reviews: [], error: String(error) }
    }
    for (const before of previous?.threads ?? []) {
      const after = next.threads.find(t => t.name === before.name)
      if (before.isBusy && after && !after.isBusy) $.ui.toast(finishedLine(after, next.reviews), { timeoutMs: 8000 })
    }
    await update($, snapshot, () => next)
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
    await $.ui.open({ id: PANE, title: 'Codex' })
    await tick($, true)

    return { text: 'Codex threads pane opened.' }
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    const command = e.command
    if (command.includes('cc-codex-triage')) {
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
    const { Box, Text } = $.ui.resolve(e)
    const shot = await read($, snapshot)
    const now = await $.clock.now()
    const width = Math.max(20, e.props.bodyColumns)
    const cut = (text: string) => (text.length > width ? `${text.slice(0, width - 1)}…` : text)

    if (!shot) return <Text dimColor>Reading Codex threads…</Text>
    if (shot.error) return <Text color="red">{cut(shot.error)}</Text>

    return (
      <Box flexDirection="column">
        {shot.threads.length === 0 && <Text dimColor>No Codex threads in this context.</Text>}
        {shot.threads.map(t => (
          <Box flexDirection="column">
            <Text color={t.isBusy ? 'cyan' : undefined} dimColor={!t.isBusy}>
              {cut(
                t.isBusy
                  ? `● ${t.name} · round ${t.rounds + 1} · ${elapsed(now - (t.startedAtMs ?? now))}`
                  : `○ ${t.name} · ${rounds(t.rounds)} · ${ago(now - t.lastActivityMs)}`,
              )}
            </Text>
            {t.isBusy && t.event && <Text>{cut(`  ${t.event}`)}</Text>}
            {t.topic && <Text dimColor>{cut(`  ${t.topic}`)}</Text>}
          </Box>
        ))}
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
