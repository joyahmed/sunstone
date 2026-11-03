#!/usr/bin/env node
// Runs the mod's own figure code (hooks/figure.ts, via Node's type stripping, Node >= 22.18)
// against a session's subagent transcripts on disk and prints the lines the band would show.
// Usage: node figure-cli.mjs <session-dir>   (…/projects/<slug>/<session-id>)
import { readdirSync, readFileSync, statSync, openSync, readSync, closeSync } from 'node:fs'
import { join } from 'node:path'
import { TAIL_BYTES, lineOf, modelIdFromText, shortModel, tokensFromText, windowOf } from '../hooks/figure.ts'

const sub = join(process.argv[2] || '.', 'subagents')
const take = (file, pos, len) => {
  const fd = openSync(file, 'r')
  const b = Buffer.alloc(len)
  readSync(fd, b, 0, len, pos)
  closeSync(fd)
  return b.toString('utf-8')
}
for (const name of readdirSync(sub).filter(n => n.endsWith('.jsonl')).sort()) {
  const file = join(sub, name)
  const id = name.slice('agent-'.length, -'.jsonl'.length)
  const { size } = statSync(file)
  const tail = take(file, Math.max(0, size - TAIL_BYTES), Math.min(size, TAIL_BYTES))
  const head = take(file, 0, Math.min(size, TAIL_BYTES))
  let meta = {}
  try { meta = JSON.parse(readFileSync(join(sub, `agent-${id}.meta.json`), 'utf-8')) } catch {}
  const modelId = modelIdFromText(head) || modelIdFromText(tail) || meta.model || ''
  const row = { id, label: meta.description || id, model: shortModel(modelId), tokens: tokensFromText(tail), win: windowOf(modelId), isDone: false }
  console.log(`${id}  ${lineOf(row)}`)
}
