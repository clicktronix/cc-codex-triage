const SUFFIXES = [
  'review-state',
  'detach-status',
  'stream',
  'active',
  'rounds',
  'topic',
  'log',
  'id',
] as const

export type Suffix = (typeof SUFFIXES)[number]

export function splitStateName(file: string): { thread: string; suffix: Suffix } | null {
  for (const suffix of SUFFIXES) {
    const tail = `.${suffix}`
    if (file.length > tail.length && file.endsWith(tail)) {
      return { thread: file.slice(0, -tail.length), suffix }
    }
  }
  return null
}

// The driver's lease grammar, as thread-index.sh reads it: no repair, no bare
// or leading zero (kill -0 0 signals the process group), at most 12 digits.
export function leasePid(text: string): string | null {
  return /^[1-9][0-9]{0,11}$/.test(text) ? text : null
}

export function fields(text: string): Record<string, string> {
  const out: Record<string, string> = {}
  for (const line of text.split('\n')) {
    const at = line.indexOf('=')
    if (at > 0 && !(line.slice(0, at) in out)) out[line.slice(0, at)] = line.slice(at + 1)
  }
  return out
}

function oneLine(text: string): string {
  return text.replace(/\s+/g, ' ').trim()
}

// Shortens a line that is already redacted: cutting first could leave a credential
// shorter than redact.sh's patterns match, and so visible.
export function clip(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
}

function shellCommand(command: string): string {
  const wrapped = /^\S*\/(?:ba|z)?sh -lc (['"])([\s\S]*)\1$/.exec(command)
  return wrapped?.[2] ?? command
}

const PROGRAM = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/
const SCRIPT = /^[A-Za-z0-9][A-Za-z0-9._/-]*\.[a-z]{1,5}$/
const INTERPRETERS = new Set(['bash', 'sh', 'zsh', 'python', 'python3', 'node', 'bun', 'deno', 'ruby', 'perl'])

function base(word: string): string {
  return word.slice(word.lastIndexOf('/') + 1)
}

// What a command is, never what it carries: the program, and for an interpreter
// the script it runs. Any other word may be a credential (`redis-cli auth <pw>`
// reads like a subcommand), so none is shown.
export function commandSummary(command: string): string {
  const words = oneLine(shellCommand(command)).split(' ')
  const [program, next] = words
  if (!program || !PROGRAM.test(program)) return '…'
  const shown = [base(program)]
  if (INTERPRETERS.has(base(program)) && next && SCRIPT.test(next)) shown.push(base(next))
  return shown.length < words.length ? `${shown.join(' ')} …` : shown.join(' ')
}

// The driver's stream is `mktemp "$TMPDIR/cc-codex-<thread>.XXXXXX"` plus `.jsonl`;
// a pointer naming anything else is not followed.
export function isStreamPath(thread: string, path: string): boolean {
  if (!path.startsWith('/') || path.split('/').includes('..')) return false
  const name = base(path)
  const prefix = `cc-codex-${thread}.`
  return name.startsWith(prefix) && /^[A-Za-z0-9]{6}\.jsonl$/.test(name.slice(prefix.length))
}

type CodexItem = {
  type?: string
  command?: string
  text?: string
  server?: string
  tool?: string
  query?: string
  changes?: { path?: string }[]
}

// One unshortened line for the latest Codex event in a `codex exec --json` tail.
// Command output and reply text are never shown: only what kind of step runs.
export function lastEvent(jsonl: string): string | null {
  const lines = jsonl.split('\n')
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i]?.trim()
    if (!line?.startsWith('{')) continue
    let event: { type?: string; item?: CodexItem }
    try {
      event = JSON.parse(line)
    } catch {
      continue
    }
    const item = event.item
    if (event.type === 'turn.started') return 'thinking'
    if (!item || item.type === 'error') continue
    const done = event.type === 'item.completed'
    switch (item.type) {
      case 'command_execution':
        return `${done ? 'ran' : 'runs'}: ${commandSummary(item.command ?? '')}`
      case 'file_change':
        return `edits ${item.changes?.map(c => c.path).filter(Boolean).join(', ') || 'files'}`
      case 'mcp_tool_call':
        return `calls ${item.server ?? '?'}.${item.tool ?? '?'}`
      case 'web_search':
        return `searches: ${oneLine(item.query ?? '')}`
      case 'reasoning':
        return 'thinking'
      case 'agent_message':
        return done ? 'replied' : 'writing a reply'
      case 'todo_list':
        return 'updates its plan'
    }
  }
  return null
}

// The last REPLY section of a thread log tail. The driver writes markers at column 0
// and indents every body line two spaces, so no prompt or reply text reads as a marker.
// A reply as the pane shows it: Markdown marks a terminal draws literally are dropped and the
// words kept. Fenced code stays literal, its fence lines blank, since a `#` or `**` there is code.
// Single `*` and `_` stay, being often part of a name (`__init__`, `snake_case`).
const OPEN_FENCE = /^ {0,3}(`{3,}[^`]*|~{3,}.*)$/

export function plainReply(lines: string[]): string[] {
  let fence: string | null = null
  return lines.map(line => {
    if (fence) {
      const close = / {0,3}([`~]+)\s*$/.exec(line)?.[1] ?? ''
      if (line.length - line.trimStart().length <= 3 && close === line.trim()
        && close[0] === fence[0] && close.length >= fence.length && !close.includes(fence[0] === '`' ? '~' : '`')) fence = null
      return fence ? line : ''
    }
    const open = OPEN_FENCE.exec(line)?.[1]
    if (open) {
      fence = open[0]?.repeat(/^([`~])\1*/.exec(open)?.[0].length ?? 3) ?? null
      return ''
    }
    return plainLine(line)
  })
}

export function plainLine(line: string): string {
  return plainInline(line.replace(/^(\s*)#{1,6}\s+/, '$1').replace(/^(\s*)>\s?/, '$1'))
}

const LINK_TARGET_MAX = 512

// Three passes, each linear: code spans first (a backtick run closes at the next run of the same
// length), then `**` pairs and [text](target) links outside them; the output is built once.
function plainInline(text: string): string {
  const n = text.length
  // Code spans: start -> [content start, content end, span end].
  const runs: [number, number][] = []
  for (let i = 0; i < n; ) {
    if (text[i] !== '`') { i += 1; continue }
    let j = i
    while (text[j] === '`') j += 1
    runs.push([i, j - i])
    i = j
  }
  const byLength = new Map<number, number[]>()
  for (const [pos, len] of runs) {
    const same = byLength.get(len)
    if (same) same.push(pos)
    else byLength.set(len, [pos])
  }
  const cursor = new Map<number, number>()
  const spans = new Map<number, [number, number, number]>()
  let coveredTo = 0
  for (const [pos, len] of runs) {
    if (pos < coveredTo) continue
    const same = byLength.get(len) ?? []
    let k = cursor.get(len) ?? 0
    while (k < same.length && (same[k] ?? 0) <= pos) k += 1
    cursor.set(len, k)
    const close = same[k]
    if (close === undefined) continue
    spans.set(pos, [pos + len, close, close + len])
    coveredTo = close + len
    cursor.set(len, k + 1)
  }
  // Outside code: which characters are code, bold marks, and the next `]`.
  const inCode = new Uint8Array(n)
  for (const [pos, [, , end]] of spans) inCode.fill(1, pos, end)
  const bold: number[] = []
  for (let i = 0; i < n - 1; i += 1) {
    if (!inCode[i] && !inCode[i + 1] && text[i] === '*' && text[i + 1] === '*') {
      bold.push(i)
      i += 1
    }
  }
  const drop = new Uint8Array(n)
  for (let k = 0; k + 1 < bold.length; k += 2) {
    const [open, close] = [bold[k] ?? 0, bold[k + 1] ?? 0]
    if (close > open + 2) drop.fill(1, open, open + 2), drop.fill(1, close, close + 2)
  }
  const nextClose = new Int32Array(n + 1).fill(-1)
  for (let i = n - 1; i >= 0; i -= 1) nextClose[i] = !inCode[i] && text[i] === ']' ? i : (nextClose[i + 1] ?? -1)
  const targetEnd = new Map<number, number>()
  const endOf = (from: number) => {
    const known = targetEnd.get(from)
    if (known !== undefined) return known
    let depth = 1
    let end = -1
    for (let j = from; j < n && j < from + LINK_TARGET_MAX; j += 1) {
      const c = text[j]
      if (c === ' ' || inCode[j]) break
      if (c === '(') depth += 1
      if (c === ')' && --depth === 0) { end = j; break }
    }
    targetEnd.set(from, end)
    return end
  }
  const linkTail = new Map<number, number>()
  for (let i = 0; i < n; i += 1) {
    if (inCode[i] || drop[i] || text[i] !== '[') continue
    const close = nextClose[i + 1] ?? -1
    if (close <= i + 1 || text[close + 1] !== '(') continue
    const end = endOf(close + 2)
    if (end === -1) continue
    drop[i] = 1
    linkTail.set(close, end)
  }
  let out = ''
  for (let i = 0; i < n; ) {
    const span = spans.get(i)
    if (span) { out += text.slice(span[0], span[1]); i = span[2]; continue }
    const tail = linkTail.get(i)
    if (tail !== undefined) { i = tail + 1; continue }
    if (!drop[i]) out += text[i]
    i += 1
  }
  return out
}

export function lastReply(log: string): string | null {
  const lines = log.split('\n')
  const start = lines.lastIndexOf('REPLY:')
  const end = start === -1 ? -1 : lines.indexOf('---', start + 1)
  if (end === -1) return null
  return lines
    .slice(start + 1, end)
    .map(line => line.replace(/^ {2}/, ''))
    .join('\n')
    .replace(/\s+$/, '')
}

// Terminal cells, not characters: an emoji (by its Unicode property, not a hand list)
// and the East Asian wide and fullwidth blocks take two, so a line cut by its length
// alone still wraps. Counted per grapheme, so a ZWJ sequence or an emoji with VS16 is
// one wide glyph and a combining mark adds nothing.
const WIDE: [number, number][] = [
  [0x1100, 0x115f], [0x2e80, 0x303e], [0x3041, 0x33ff], [0x3400, 0x4dbf], [0x4e00, 0x9fff],
  [0xa000, 0xa4cf], [0xac00, 0xd7a3], [0xf900, 0xfaff], [0xfe30, 0xfe4f], [0xff00, 0xff60],
  [0xffe0, 0xffe6], [0x20000, 0x3fffd],
]
const EMOJI = /\p{Emoji_Presentation}|\uFE0F/u
const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' })

function graphemes(text: string): string[] {
  return [...segmenter.segment(text)].map(part => part.segment)
}

function cellsOf(glyph: string): number {
  const code = glyph.codePointAt(0) ?? 0
  return EMOJI.test(glyph) || WIDE.some(([from, to]) => code >= from && code <= to) ? 2 : 1
}

export function cells(text: string): number {
  return graphemes(text).reduce((sum, glyph) => sum + cellsOf(glyph), 0)
}

export function fit(text: string, width: number): string {
  if (cells(text) <= width) return text
  let out = ''
  let used = 0
  for (const glyph of graphemes(text)) {
    if (used + cellsOf(glyph) > width - 1) break
    out += glyph
    used += cellsOf(glyph)
  }
  return `${out}…`
}

export function ago(ms: number): string {
  const m = Math.floor(Math.max(0, ms) / 60_000)
  if (m < 1) return 'just now'
  if (m < 60) return `${m}m ago`
  if (m < 48 * 60) return `${Math.floor(m / 60)}h ago`
  return `${Math.floor(m / (24 * 60))}d ago`
}

export function rounds(n: number): string {
  return n === 1 ? '1 round' : `${n} rounds`
}

export function elapsed(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000))
  const m = Math.floor(s / 60)
  return m >= 60 ? `${Math.floor(m / 60)}h${String(m % 60).padStart(2, '0')}m` : `${m}:${String(s % 60).padStart(2, '0')}`
}
