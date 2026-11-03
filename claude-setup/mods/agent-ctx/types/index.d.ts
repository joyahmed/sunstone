export type AgentCtxRow = {
  id: string
  label: string
  model: string
  tokens: number | null
  win: number
  isDone: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'agent-ctx': { rows: AgentCtxRow[]; isHidden: boolean }
  }
}
