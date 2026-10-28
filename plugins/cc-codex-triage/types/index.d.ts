export type ThreadRow = {
  name: string
  topic: string
  rounds: number
  lastActivityMs: number
  isBusy: boolean
  startedAtMs: number | null
  event: string | null
  preview: string | null
}

export type ReviewRow = {
  name: string
  status: string
  verdict: string
  isGateEligible: boolean
}

export type Snapshot = {
  atMs: number
  stateDir: string | null
  threads: ThreadRow[]
  reviews: ReviewRow[]
  error: string | null
}

export type Reply = {
  thread: string
  forMs: number
  status: 'loading' | 'ready' | 'failed'
  lines: string[] | null
}

declare module 'claude-code' {
  interface PluginState {
    'cc-codex-triage': { snapshot: Shaped<Snapshot | null>; reply: Shaped<Reply | null> }
  }
}
