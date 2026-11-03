// Pure figure logic for the agent-ctx mod. No `$`, no Node: the mod imports it, and
// `node figure-cli.mjs` runs the same code against transcripts on disk.
//
// COPIED (not imported) from sunstone claude-setup/config/hooks/context-cap.mjs `readAgent`,
// because a hooks module has no Node fs and context-cap.mjs runs its main on import.
// Keep the two in step: tokens = input + cache_read + cache_creation of the LAST assistant
// message's usage (output is NOT counted - context-cap does not count it either);
// window = N * 1M when a modelId/model carries `[Nm]`, else 200k.

export const TAIL_BYTES = 512 * 1024

export type Row = {
  id: string
  label: string
  model: string
  tokens: number | null
  win: number
  isDone: boolean
}

/** Tokens of the last assistant message's usage in `text`, or null when none. */
export function tokensFromText(text: string): number | null {
  const lines = text.split('\n')
  for (let i = lines.length - 1; i >= 0; i--) {
    const l = lines[i] ?? ""
    if (!l.includes('"usage"')) continue
    let d: any
    try {
      d = JSON.parse(l)
    } catch {
      continue
    }
    const u = d && d.type === 'assistant' && d.message && d.message.usage
    if (u) return (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0)
  }
  return null
}

/** First model id in `text` (attachment identity modelId, else message.model), or ''. */
export function modelIdFromText(text: string): string {
  for (const l of text.split('\n')) {
    if (!l.includes('"modelId"') && !l.includes('"model"')) continue
    let d: any
    try {
      d = JSON.parse(l)
    } catch {
      continue
    }
    const id = String((d.attachment && d.attachment.identity && d.attachment.identity.modelId) || (d.message && d.message.model) || '')
    if (id) return id
  }
  return ''
}

/** The window for a model id: `[Nm]` means N million, otherwise the standard 200k. */
export function windowOf(modelId: string): number {
  const m = /\[(\d+)m\]/i.exec(modelId)
  return m ? parseInt(m[1] ?? "0", 10) * 1e6 || 200000 : 200000
}

/** `claude-opus-5-5[1m]` -> `opus`; an alias (`sonnet`) stays as it is. */
export function shortModel(modelId: string): string {
  const m = /(opus|sonnet|haiku|fable)/i.exec(modelId)
  return m?.[1] ? m[1].toLowerCase() : modelId || "?"
}

const k = (n: number) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : `${Math.round(n / 1000)}k`)

export function pctOf(row: Row): number | null {
  return row.tokens === null ? null : Math.round((row.tokens / row.win) * 100)
}

/** `!` from 60%, `!!` from 70% (the handover point), nothing below. */
export function level(pct: number | null): 'ok' | 'warn' | 'red' {
  if (pct === null || pct < 60) return 'ok'
  return pct >= 70 ? 'red' : 'warn'
}

export function lineOf(row: Row): string {
  const pct = pctOf(row)
  const label = row.label.length > 40 ? `${row.label.slice(0, 39)}…` : row.label
  const fig = pct === null ? 'no usage yet' : `${pct}% (${k(row.tokens as number)}/${k(row.win)})`
  const mark = { ok: '', warn: ' !', red: ' !! HANDOVER' }[level(pct)]
  return `${label} · ${row.model} · ${fig}${mark}${row.isDone ? ' · done' : ''}`
}
