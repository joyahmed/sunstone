// agent-ctx: one line per running subagent of this session, above the prompt:
//   A4 holiday lock and import · opus · 58% (116k/200k)
// `!` (yellow) from 60%, `!! HANDOVER` (red) from 70%. Finished agents stay dimmed for a minute.
// Off: /agent-ctx (toggles), or env AGENT_CTX=0 before the session starts.
import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { AgentCtxRow } from '../types'
import { TAIL_BYTES, level, lineOf, modelIdFromText, pctOf, shortModel, tokensFromText, windowOf } from './figure'

const rows = atom({ plugin: 'agent-ctx', key: 'rows' } as const, [] as AgentCtxRow[])
const isHidden = atom({ plugin: 'agent-ctx', key: 'isHidden' } as const, false)

const TICK_MS = 3000
const DONE_KEEP_MS = 60_000
const LIVE = new Set(['pending', 'running', 'waiting'])

type Cached = { mtimeMs: number; tokens: number | null; modelId: string; label: string }

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    if ((await $.env.get('AGENT_CTX')) === '0') return next(e)
    await $.command.register({ name: 'agent-ctx', description: 'Show or hide the subagent context band' })

    // A cache only: it starts over on a reload, which costs one re-read per agent.
    let dir: string | null = null
    const cache = new Map<string, Cached>()
    const doneAt = new Map<string, number>()
    let isBusy = false

    // One end of a transcript, at most TAIL_BYTES: `tail`/`head -c` so a big file is never
    // read whole; $.fs.read (whole file, max 4 MiB) where those commands are missing.
    const chunk = async (path: string, size: number, end: 'head' | 'tail'): Promise<string> => {
      if (size > TAIL_BYTES) {
        try {
          const r = await $.process.run([end, '-c', String(TAIL_BYTES), path])
          if (r.exitCode === 0) return r.stdout
        } catch {}
        if (size > 4 * 1024 * 1024) return ''
      }
      const t = await $.fs.read(path)
      return t.length <= TAIL_BYTES ? t : end === 'tail' ? t.slice(-TAIL_BYTES) : t.slice(0, TAIL_BYTES)
    }

    const findDir = async (): Promise<string | null> => {
      const home = (await $.env.get('HOME')) || (await $.env.get('USERPROFILE'))
      const sid = await $.session.id()
      if (!home || !sid) return null
      const root = `${home}/.claude/projects`
      const slug = (await $.session.cwd()).replace(/[^A-Za-z0-9]/g, '-')
      if (await $.fs.exists(`${root}/${slug}/${sid}`)) return `${root}/${slug}/${sid}`
      for (const p of await $.fs.list(root)) {
        if (await $.fs.exists(`${root}/${p.name}/${sid}`)) return `${root}/${p.name}/${sid}`
      }
      return null
    }

    const figure = async (id: string, description: string): Promise<AgentCtxRow | null> => {
      const file = `${dir}/subagents/agent-${id}.jsonl`
      let st: { size: number; mtimeMs: number }
      try {
        st = await $.fs.stat(file)
      } catch {
        return null
      }
      let c = cache.get(id)
      if (!c || c.mtimeMs !== st.mtimeMs) {
        const text = await chunk(file, st.size, 'tail')
        let modelId = c?.modelId || ''
        let label = c?.label || description
        if (!c) {
          try {
            const meta = JSON.parse(await $.fs.read(`${dir}/subagents/agent-${id}.meta.json`))
            label = meta.description || label
            modelId = meta.model || ''
          } catch {}
          // The real id (and its [1m] marker) is near the head: read it once per agent.
          const head = st.size > TAIL_BYTES ? await chunk(file, st.size, 'head') : text
          modelId = modelIdFromText(head) || modelIdFromText(text) || modelId
        }
        c = { mtimeMs: st.mtimeMs, tokens: tokensFromText(text) ?? c?.tokens ?? null, modelId, label }
        cache.set(id, c)
      }
      return { id, label: c.label, model: shortModel(c.modelId), tokens: c.tokens, win: windowOf(c.modelId), isDone: false }
    }

    const tick = async () => {
      if (isBusy) return
      isBusy = true
      try {
        if (!dir) dir = await findDir()
        if (!dir) return
        const agents = (await $.agent.list()).filter(a => !a.teammateId)
        const now = await $.clock.now()
        const prev = await read($, rows)
        const fresh: AgentCtxRow[] = []
        for (const a of agents) {
          if (!LIVE.has(a.status)) continue
          const r = await figure(a.id, a.description)
          if (r) fresh.push(r)
        }
        // Ended or dropped from the list: dimmed for a minute, then gone.
        for (const p of prev) {
          if (fresh.some(n => n.id === p.id)) continue
          if (!doneAt.has(p.id)) doneAt.set(p.id, now)
          if (now - (doneAt.get(p.id) as number) < DONE_KEEP_MS) fresh.push({ ...p, isDone: true })
        }
        if (JSON.stringify(prev) !== JSON.stringify(fresh)) await update($, rows, () => fresh)
      } catch {
      } finally {
        isBusy = false
      }
    }

    $.clock.every(TICK_MS, () => void tick())
    return next(e)
  })

  on('command.run', { command: 'agent-ctx' }, async $ => {
    await update($, isHidden, v => !v)
    const hidden = await read($, isHidden)
    return { text: hidden ? 'Agent context band hidden. /agent-ctx shows it again.' : 'Agent context band shown.' }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, rows)
    if (e.props.hasSurvey || list.length === 0 || (await read($, isHidden))) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        {list.map(r => {
          const lv = level(pctOf(r))
          const color = r.isDone ? undefined : lv === 'red' ? 'red' : lv === 'warn' ? 'yellow' : undefined
          return (
            <Text key={r.id} dimColor={r.isDone} color={color}>
              {lineOf(r)}
            </Text>
          )
        })}
      </Box>
    )
  })
}
