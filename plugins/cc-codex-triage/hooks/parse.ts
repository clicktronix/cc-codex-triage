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

function oneLine(text: string, max: number): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat
}

function shellCommand(command: string): string {
  const wrapped = /^\S*\/(?:ba|z)?sh -lc (['"])([\s\S]*)\1$/.exec(command)
  return wrapped?.[2] ?? command
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

// One line for the latest Codex event in a `codex exec --json` tail. Command
// output is never shown: only what Codex runs, edits, searches or says.
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
        return `${done ? 'ran' : 'runs'}: ${oneLine(shellCommand(item.command ?? ''), 80)}`
      case 'file_change':
        return `edits ${item.changes?.map(c => c.path).filter(Boolean).join(', ') || 'files'}`
      case 'mcp_tool_call':
        return `calls ${item.server ?? '?'}.${item.tool ?? '?'}`
      case 'web_search':
        return `searches: ${oneLine(item.query ?? '', 60)}`
      case 'reasoning':
        return 'thinking'
      case 'agent_message':
        return done ? `says: ${oneLine(item.text ?? '', 80)}` : 'writing a reply'
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
