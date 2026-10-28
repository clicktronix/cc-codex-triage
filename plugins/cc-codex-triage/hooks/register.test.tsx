import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { commandSummary, isStreamPath, lastEvent, lastReply, leasePid, splitStateName } from './parse'

const DIR = '/repo/.git/cc-codex-triage/threads'
const STREAM = '/tmp/cc-codex-review-a.b.Ab12Cd.jsonl'
const START = 1_800_000_000_000
const tailed: string[] = []
const logReads: string[] = []

const EVENTS = [
  '{"type":"thread.started","thread_id":"01a179cb-bf55-7af1-b216-fc71b6980e63"}',
  '{"type":"turn.started"}',
  '{"type":"item.started","item":{"id":"item_2","type":"command_execution","command":"/bin/zsh -lc \'npm test -- auth\'","aggregated_output":"","exit_code":null,"status":"in_progress"}}',
].join('\n')

const PANE = {
  plugin: 'cc-codex-triage',
  component: 'Pane',
  requestId: 'codex-threads',
  props: {
    title: 'Codex',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 20 },
    view: {},
  },
} as const

const BAND = {
  plugin: 'cc-codex-triage',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 3,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 3 },
    view: {},
  },
} as const

// A log's mtime moves with its content, as the driver's appends move it.
function logMs(text = ''): number {
  return START - 3_660_000 + text.length
}

function logOf(...replies: string[]): string {
  return replies
    .map((reply, i) => `[2026-10-28T18:53:1${i}Z] mode=resume thread=t round=${i + 1}\nPROMPT:\n  q\nREPLY:\n${reply.split('\n').map(l => `  ${l}`).join('\n')}\n---\n`)
    .join('')
}

type Faults = {
  isListBroken: boolean
  links?: string[]
  // Runs before a log is read; 'deny' fails that read.
  beforeLogRead?: (path: string) => Promise<'deny' | void>
}

function world(
  on: On,
  files: Record<string, string>,
  alive: Set<string>,
  isPaneShown = true,
  stream = EVENTS,
  faults: Faults = { isListBroken: false },
) {
  const toasts: string[] = []
  tailed.length = 0
  logReads.length = 0
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('command.register', () => ({ value: { command: 'codex-pane' } }))
  on('ui.panes', () => ({
    value: isPaneShown
      ? [{ id: 'codex-threads', title: 'Codex', isShown: true, isFocused: false, isPlaced: true }]
      : [],
  }))
  on('ui.toast', (_, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('fs.exists', (_, e) => ({ value: e.path === DIR }))
  // Every path is an existing regular file, so only the mod's own checks stop a read.
  on('fs.stat', (_, e) => ({
    value: {
      kind: 'file' as const,
      size: e.path.startsWith(`${DIR}/`) ? (files[e.path.slice(DIR.length + 1)]?.length ?? 0) : stream.length,
      mtimeMs: START,
      isLink: faults.links?.includes(e.path) ?? false,
    },
  }))
  on('fs.list', () => {
    if (faults.isListBroken) return { deny: 'EIO' }
    return {
    value: Object.keys(files).map(name => ({
      name,
      kind: 'file' as const,
      size: files[name]?.length ?? 0,
      mtimeMs: name.endsWith('.active') ? START - 75_000 : name.endsWith('.log') ? logMs(files[name]) : START - 3_600_000,
      isLink: false,
    })),
    }
  })
  on('fs.read', (_, e) => {
    const name = e.path.slice(DIR.length + 1)
    const text = e.path.startsWith(`${DIR}/`) ? files[name] : undefined
    return text === undefined ? { deny: `ENOENT ${e.path}` } : { value: text }
  })
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  on('process.run', async (_, e) => {
    const [cmd, arg] = e.argv
    const done = (stdout: string, exitCode = 0) => ({
      value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    })
    if (cmd === 'bash' && arg?.endsWith('/scripts/state-dir.sh')) return done(`${DIR}\n`)
    // redact.sh's bearer rule: a token shorter than twelve characters is left alone.
    if (cmd === 'bash' && arg?.endsWith('/scripts/redact.sh')) {
      return done((e.init?.stdin ?? '').replace(/([Bb]earer )[A-Za-z0-9._~+/-]{12,}=*/g, '$1[redacted]'))
    }
    if (cmd === 'kill') return done('', alive.has(e.argv[2] ?? '') ? 0 : 1)
    if (cmd === 'tail') {
      const path = e.argv[3] ?? ''
      tailed.push(path)
      if (!path.startsWith(`${DIR}/`)) return done(stream)
      logReads.push(path)
      if ((await faults.beforeLogRead?.(path)) === 'deny') return done('', 1)
      const text = files[path.slice(DIR.length + 1)]
      return text === undefined ? done('', 1) : done(text.slice(-Number(e.argv[2])))
    }
    return done('', 1)
  })
  return toasts
}

const FILES = {
  'review-a.b.id': '01a179cb-bf55-7af1-b216-fc71b6980e63',
  'review-a.b.log': 'round=1',
  'review-a.b.rounds': '2',
  'review-a.b.topic': 'auth session fix',
  'review-a.b.active': '4242',
  'review-a.b.stream': `pid=4242\npath=${STREAM}\n`,
  'review-a.b.review-state': 'status=PENDING\nverdict=-\ngate_eligible=false\n',
  'plan-x.id': '01a179cb-bf55-7af1-b216-fc71b6980e64',
  'plan-x.log': 'round=1',
  'plan-x.rounds': '5',
  'plan-x.archive.ab12': 'old',
}

describe('parse', () => {
  test('the last reply is read from the log, markers at column 0 only', async () => {
    expect(lastReply(logOf('first', 'second\n\n  indented\nREPLY:\n---'))).toBe('second\n\n  indented\nREPLY:\n---')
    expect(lastReply(`${logOf('done')}[x] mode=resume\nPROMPT:\n  q\nREPLY:\n  half`)).toBe(null)
    expect(lastReply('round=1')).toBe(null)
  })

  test('a thread name may hold dots; archives are not state files', async () => {
    expect(splitStateName('review-a.b.review-state')).toEqual({ thread: 'review-a.b', suffix: 'review-state' })
    expect(splitStateName('x.active.lock')).toBe(null)
    expect(splitStateName('plan-x.archive.ab12')).toBe(null)
  })

  test('a command shows its program and plain words only, never its arguments', async () => {
    expect(commandSummary("/bin/zsh -lc 'npm test -- auth'")).toBe('npm …')
    expect(commandSummary('bash tests/driver-regression.sh')).toBe('bash driver-regression.sh')
    expect(commandSummary('git status')).toBe('git …')
    expect(commandSummary('python3 scripts/check.py --fast')).toBe('python3 check.py …')
    const secrets = [
      'curl -u alice:SYNTHETIC_PASSWORD https://example.test',
      'psql postgresql://app:SYNTHETIC_PASSWORD@db.internal/app',
      'aws configure set aws_secret_access_key SYNTHETICabc123SECRET',
      'mytool SYNTHETIC9secret8TOKEN',
      'API_KEY=SYNTHETIC123 node run.js',
      'redis-cli auth synthetichunter',
    ]
    for (const command of secrets) expect(commandSummary(command).toUpperCase()).not.toContain('SYNTHETIC')
  })

  test('only a driver-shaped stream path is read', async () => {
    expect(isStreamPath('review-a.b', '/var/folders/x/T/cc-codex-review-a.b.Ab12Cd.jsonl')).toBe(true)
    expect(isStreamPath('review-a.b', '/repo/.git/cc-codex-triage/threads/review-a.b.last-error.jsonl')).toBe(false)
    expect(isStreamPath('review-a.b', '/tmp/cc-codex-review-a.b.last-error.jsonl')).toBe(false)
    expect(isStreamPath('review-a.b', '/tmp/cc-codex-other.Ab12Cd.jsonl')).toBe(false)
    expect(isStreamPath('review-a.b', 'cc-codex-review-a.b.Ab12Cd.jsonl')).toBe(false)
    expect(isStreamPath('review-a.b', '/tmp/../etc/cc-codex-review-a.b.Ab12Cd.jsonl')).toBe(false)
  })

  test('the lease grammar takes no repair', async () => {
    expect(leasePid('4242')).toBe('4242')
    for (const bad of ['0', '0123', ' 42', '42\n', '1234567890123', 'abc']) expect(leasePid(bad)).toBe(null)
  })

  test('the latest event wins, and command output is never shown', async () => {
    expect(lastEvent(EVENTS)).toBe('runs: npm …')
    const finished = `${EVENTS}\n{"type":"item.completed","item":{"type":"agent_message","text":"found password=hunter2 in .env"}}`
    expect(lastEvent(finished)).toBe('replied')
    expect(lastEvent('{"type":"item.completed","item":{"type":"error","message":"warn"}}\nnot json')).toBe(null)
  })
})

describe('mod', () => {
  test('the pane lists the busy thread first, with its live event and the review', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    world(on, FILES, new Set(['4242']))
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts[0]).toBe('● review-a.b · round 3 · 1:15')
    expect(texts).toContain('  runs: npm …')
    expect(texts).toContain('○ plan-x · 5 rounds · 1h ago')
    expect(texts).toContain('review-a.b · PENDING · -')
    await ui.unmount()
  })

  test('the pane asks for a narrow dock when the person opens it', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    world(on, FILES, new Set(), false)
    const opened: { id: string; columns?: number }[] = []
    on('ui.open', (_, e) => {
      opened.push({ id: e.id, columns: e.columns })
      return { value: { isPlaced: true } }
    })
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const { text } = await $.command.run({
      command: 'codex-pane',
      args: '',
      origin: { kind: 'composer' },
      presentation: { isFullscreen: true, columns: 200 },
    })
    expect(text).toBe('Codex threads pane opened.')
    expect(opened).toEqual([{ id: 'codex-threads', columns: 48 }])
  })

  test('the band shows a running dispatch and steps aside when none runs', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const alive = new Set(['4242'])
    const toasts = world(on, FILES, alive)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect((await band.find({ type: 'Text', text: /review-a\.b/ }))?.text).toBe(
      ' · review-a.b · round 3 · 1:15 · runs: npm …',
    )
    await band.unmount()

    alive.delete('4242')
    await clock.advance(2000)
    expect(toasts).toEqual(['Codex review-a.b: round 2 finished'])

    const idle = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await idle.find({ type: 'Text', text: /Codex/ })).toBeUndefined()
    await idle.unmount()
  })

  test('a first dispatch shows before its thread has an .id', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    world(
      on,
      { 'fresh.active': '4242', 'fresh.stream': `pid=4242\npath=${STREAM}\n` },
      new Set(['4242']),
    )
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await ui.find({ type: 'Text', text: /fresh/ }))?.text).toBe('● fresh · round 1 · 1:15')
    await ui.unmount()
  })

  test('a stream pointer from another PID is not read', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    world(on, { ...FILES, 'review-a.b.stream': `pid=9999\npath=${STREAM}\n` }, new Set(['4242']))
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: /runs:/ })).toBeUndefined()
    await ui.unmount()
  })

  test('a credential in a command never reaches the band', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const head = "curl -H 'X-Pad: "
    const tail = "' -H 'Authorization: Bearer "
    const prefix = `${head}${'p'.repeat(71 - head.length - tail.length)}${tail}`
    const command = `${prefix}SYNTHETICTOKENabcdefghijklmnopqrstuvwxyz0123456789' https://example.test/`
    const stream = `{"type":"item.started","item":{"type":"command_execution","command":${JSON.stringify(command)}}}`
    world(on, FILES, new Set(['4242']), true, stream)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    const line = (await band.find({ type: 'Text', text: /review-a\.b/ }))?.text ?? ''
    expect(line).toContain('runs: curl …')
    expect(line).not.toContain('SYNTHETI')
    await band.unmount()
  })

  test('stale leases do not crowd a live first dispatch out of the list', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const files: Record<string, string> = { 'fresh.active': '4242', 'fresh.stream': `pid=4242\npath=${STREAM}\n` }
    for (let n = 0; n < 13; n++) {
      Object.assign(files, { [`old${n}.id`]: 'x', [`old${n}.log`]: 'round=1', [`old${n}.active`]: `9${n}` })
    }
    world(on, files, new Set(['4242']))
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await ui.find({ type: 'Text', text: /fresh/ }))?.text).toBe('● fresh · round 1 · 1:15')
    await ui.unmount()
  })

  test('a foreground dispatch is watched while the Bash call runs', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const alive = new Set<string>()
    const toasts = world(on, FILES, alive, false)
    let release = () => {}
    const held = new Promise<void>(resolve => {
      release = resolve
    })
    on('tool.call', async () => {
      alive.add('4242')
      await held
      alive.delete('4242')
      return { result: {} }
    })
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const call = $.tool.call({ tool: 'Bash', command: 'bash ~/.claude/plugins/cache/cc-codex-triage/x/scripts/dispatch.sh t' })
    await clock.advance(2000)
    release()
    await call
    await clock.advance(1)
    expect(toasts).toEqual(['Codex review-a.b: round 2 finished'])
  })

  test('a first dispatch that ends without an .id still reports its end', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const files: Record<string, string> = { 'fresh.active': '4242', 'fresh.stream': `pid=4242\npath=${STREAM}\n` }
    const alive = new Set(['4242'])
    const toasts = world(on, files, alive)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    alive.delete('4242')
    delete files['fresh.active']
    delete files['fresh.stream']
    await clock.advance(2000)
    expect(toasts).toEqual(['Codex fresh: dispatch ended without a saved round'])
  })

  test('the lease is read as the driver reads it: no trimming beyond trailing newlines', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    world(on, { ...FILES, 'review-a.b.active': ' 4242 ' }, new Set(['4242']))
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: /●/ })).toBeUndefined()
    await ui.unmount()
  })

  test('a failed scan keeps the last known dispatch and announces nothing', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const faults = { isListBroken: false }
    const toasts = world(on, FILES, new Set(['4242']), true, EVENTS, faults)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    faults.isListBroken = true
    await clock.advance(2000)
    expect(toasts).toEqual([])
    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect(await band.find({ type: 'Text', text: /review-a\.b/ })).toBeDefined()
    await band.unmount()
  })

  test('a stream pointer outside the driver naming is not read', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    world(on, { ...FILES, 'review-a.b.stream': `pid=4242\npath=/tmp/notes.jsonl\n` }, new Set(['4242']))
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: /runs:/ })).toBeUndefined()
    expect(tailed).not.toContain('/tmp/notes.jsonl')
    await ui.unmount()
  })

  test('a thread shows the first line of its last reply, and pressing it shows the whole reply', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const long = Array.from({ length: 25 }, (_, i) => `line ${i + 1}`)
    const files = { ...FILES, 'plan-x.log': logOf('old reply', ['Bearer abcdefghijklmnop', ...long].join('\n')) }
    world(on, files, new Set())
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    const before = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(before).toContain('ctrl+x tab, then Enter: whole reply')
    expect(before).toContain('  Bearer [redacted]')
    expect(before).not.toContain('line 1')
    expect(before.some(t => t.includes('old reply') || t.includes('abcdefghijklmnop'))).toBe(false)

    await ui.press({ key: 'reply:plan-x' })
    const shown = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(shown).toContain('Bearer [redacted]')
    expect(shown).toContain('line 25')
    expect(shown.some(t => t.includes('old reply') || t.includes('abcdefghijklmnop'))).toBe(false)

    await ui.press({ key: 'thread:plan-x' })
    const after = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(after).not.toContain('line 25')
    expect(after).toContain('  Bearer [redacted]')
    await ui.unmount()
  })

  test('an open reply follows a new round of its thread', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const files: Record<string, string> = { ...FILES, 'plan-x.log': logOf('round five') }
    world(on, files, new Set())
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    await ui.press({ key: 'thread:plan-x' })
    expect((await ui.findAll({ type: 'Text' })).map(t => t.text)).toContain('round five')

    files['plan-x.log'] = logOf('round five', 'round six')
    await clock.advance(2000)
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts).toContain('round six')
    expect(texts).not.toContain('round five')
    await ui.unmount()
  })

  test('a thread log that is a symlink is not read', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const files = { ...FILES, 'plan-x.log': logOf('secret elsewhere') }
    world(on, files, new Set(), true, EVENTS, { isListBroken: false, links: [`${DIR}/plan-x.log`] })
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    await ui.press({ key: 'thread:plan-x' })
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts).toContain('No saved reply to show; see plan-x.log')
    expect(texts).not.toContain('secret elsewhere')
    expect(logReads).not.toContain(`${DIR}/plan-x.log`)
    await ui.unmount()
  })

  test('a reply longer than the first tail still shows whole', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const body = Array.from({ length: 1500 }, (_, i) => `row ${i} ${'x'.repeat(40)}`)
    const files = { ...FILES, 'plan-x.log': logOf('older', ['opening line', ...body, 'closing line'].join('\n')) }
    expect(files['plan-x.log'].length).toBeGreaterThan(65_536)
    world(on, files, new Set())
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await ui.findAll({ type: 'Text' })).map(t => t.text)).toContain('  opening line')
    await ui.press({ key: 'reply:plan-x' })
    expect((await ui.findAll({ type: 'Text' })).map(t => t.text)).toContain('closing line')
    await ui.unmount()
  })

  test('threads named like each other keep their own controls', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const files = {
      'review.id': 'a', 'review.log': logOf('reply of review'),
      'review.reply.id': 'b', 'review.reply.log': logOf('reply of review.reply'),
    }
    world(on, files, new Set())
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    await ui.press({ key: 'reply:review' })
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts).toContain('reply of review')
    expect(texts).toContain('  reply of review.reply')
    expect(texts).not.toContain('reply of review.reply')
    await ui.unmount()
  })

  test('a failed read is tried again rather than kept', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    let isBroken = true
    const files = { ...FILES, 'plan-x.log': logOf('it recovers') }
    world(on, files, new Set(), true, EVENTS, {
      isListBroken: false,
      beforeLogRead: async () => (isBroken ? 'deny' : undefined),
    })
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    await ui.press({ key: 'thread:plan-x' })
    expect((await ui.findAll({ type: 'Text' })).map(t => t.text)).toContain('Could not read the reply; trying again')

    isBroken = false
    await clock.advance(2000)
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts).toContain('it recovers')
    expect(texts).not.toContain('Could not read the reply; trying again')
    await ui.unmount()
  })

  test('a slow load does not take the pane back from a later press', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    let release = () => {}
    const held = new Promise<void>(resolve => {
      release = resolve
    })
    const files = {
      ...FILES,
      'review-a.b.log': logOf('reply of a'),
      'other.id': 'c',
      'other.active': '4343',
      'other.log': logOf('reply of other'),
    }
    world(on, files, new Set(['4242', '4343']), true, EVENTS, {
      isListBroken: false,
      beforeLogRead: async path => {
        if (path.endsWith('/review-a.b.log')) await held
        if (path.endsWith('/other.log')) release()
      },
    })
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    const first = ui.press({ key: 'thread:review-a.b' })
    await ui.press({ key: 'thread:other' })
    await first
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts).toContain('reply of other')
    expect(texts).not.toContain('reply of a')
    await ui.unmount()
  })

  test('a tail that starts mid-line never takes a reply line for a marker', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    // The latest reply holds a line "REPLY:"; its log line is "  REPLY:", and the first
    // tail is sized to start right after those two spaces.
    const closing = '\n  closing line\n---\n'
    const filler = 'y'.repeat(65_536 - 'REPLY:\n'.length - 2 - closing.length)
    const log = logOf('older', ['opening line', 'REPLY:', filler, 'closing line'].join('\n'))
    expect(log.slice(-65_536).startsWith('REPLY:\n  y')).toBe(true)
    world(on, { ...FILES, 'plan-x.log': log }, new Set())
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect((await ui.findAll({ type: 'Text' })).map(t => t.text)).toContain('  opening line')
    await ui.unmount()
  })

  test('a new round with an empty reply does not keep the old text', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const files: Record<string, string> = { ...FILES, 'plan-x.log': logOf('round five') }
    world(on, files, new Set())
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    await ui.press({ key: 'thread:plan-x' })
    files['plan-x.log'] = logOf('round five', '')
    await clock.advance(2000)
    const texts = (await ui.findAll({ type: 'Text' })).map(t => t.text)
    expect(texts).not.toContain('round five')
    expect(texts).toContain('No saved reply to show; see plan-x.log')
    await ui.unmount()
  })
})
