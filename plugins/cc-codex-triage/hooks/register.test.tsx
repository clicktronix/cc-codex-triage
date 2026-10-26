import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { lastEvent, leasePid, splitStateName } from './parse'

const DIR = '/repo/.git/cc-codex-triage/threads'
const STREAM = '/tmp/cc-codex-review-a.b.X.jsonl'
const START = 1_800_000_000_000

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

function world(
  on: On,
  files: Record<string, string>,
  alive: Set<string>,
  isPaneShown = true,
  stream = EVENTS,
  faults = { isListBroken: false },
) {
  const toasts: string[] = []
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
  on('fs.list', () => {
    if (faults.isListBroken) return { deny: 'EIO' }
    return {
    value: Object.keys(files).map(name => ({
      name,
      kind: 'file' as const,
      size: files[name]?.length ?? 0,
      mtimeMs: name.endsWith('.active') ? START - 75_000 : START - 3_600_000,
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
  on('process.run', (_, e) => {
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
    if (cmd === 'tail' && e.argv[3] === STREAM) return done(stream)
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
  test('a thread name may hold dots; archives are not state files', async () => {
    expect(splitStateName('review-a.b.review-state')).toEqual({ thread: 'review-a.b', suffix: 'review-state' })
    expect(splitStateName('x.active.lock')).toBe(null)
    expect(splitStateName('plan-x.archive.ab12')).toBe(null)
  })

  test('the lease grammar takes no repair', async () => {
    expect(leasePid('4242')).toBe('4242')
    for (const bad of ['0', '0123', ' 42', '42\n', '1234567890123', 'abc']) expect(leasePid(bad)).toBe(null)
  })

  test('the latest event wins, and command output is never shown', async () => {
    expect(lastEvent(EVENTS)).toBe('runs: npm test -- auth')
    const finished = `${EVENTS}\n{"type":"item.completed","item":{"type":"agent_message","text":"APPROVE\\n\\nno findings"}}`
    expect(lastEvent(finished)).toBe('says: APPROVE no findings')
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
    expect(texts).toContain('  runs: npm test -- auth')
    expect(texts).toContain('○ plan-x · 5 rounds · 1h ago')
    expect(texts).toContain('review-a.b · PENDING · -')
    await ui.unmount()
  })

  test('the band shows a running dispatch and steps aside when none runs', async ($, on) => {
    const clock = mock.clock(on, { now: START })
    const alive = new Set(['4242'])
    const toasts = world(on, FILES, alive)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
    await clock.advance(1)

    const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
    expect((await band.find({ type: 'Text', text: /review-a\.b/ }))?.text).toBe(
      ' · review-a.b · round 3 · 1:15 · runs: npm test -- auth',
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

  test('a credential is redacted before the event line is shortened', async ($, on) => {
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
    expect(line).toContain('Bearer [redacted]')
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
})
