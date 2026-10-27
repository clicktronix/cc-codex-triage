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
const SUBCOMMAND = /^[a-z][a-z-]{0,19}$/
const FILE = /^[A-Za-z0-9][A-Za-z0-9._/-]*\.[a-z]{1,5}$/

function base(word: string): string {
  return word.slice(word.lastIndexOf('/') + 1)
}

// What a command is, never what it carries: its program, then up to two words
// that read as a subcommand or a file name. Credentials ride in arguments, URLs
// and assignments, which no pattern list catches in full, so none of those is shown.
export function commandSummary(command: string): string {
  const words = oneLine(shellCommand(command)).split(' ')
  const [program] = words
  if (!program || !PROGRAM.test(program)) return '…'
  const shown = [base(program)]
  for (const word of words.slice(1, 3)) {
    if (SUBCOMMAND.test(word)) shown.push(word)
    else if (FILE.test(word)) shown.push(base(word))
    else break
  }
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
