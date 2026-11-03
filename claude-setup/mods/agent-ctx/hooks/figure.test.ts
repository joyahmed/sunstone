import { expect, test } from 'claude-code/testing'

import { level, lineOf, modelIdFromText, shortModel, tokensFromText, windowOf } from './figure'

const asst = (u: object) => JSON.stringify({ type: 'assistant', message: { model: 'claude-opus-5-5', usage: u } })

test('tokens: last assistant usage, input + cache read + cache creation, output not counted', async () => {
  const text = [asst({ input_tokens: 1, cache_read_input_tokens: 10, cache_creation_input_tokens: 100, output_tokens: 9 }),
    asst({ input_tokens: 2, cache_read_input_tokens: 100000, cache_creation_input_tokens: 16000, output_tokens: 500 }),
    '{"type":"user","message":{}}', 'not json "usage"'].join('\n')
  expect(tokensFromText(text)).toBe(116002)
  expect(tokensFromText('{"type":"user"}')).toBe(null)
})

test('window: [1m] in the model id means 1M, otherwise 200k', async () => {
  const head = JSON.stringify({ attachment: { identity: { modelId: 'claude-opus-5-5[1m]' } } })
  expect(windowOf(modelIdFromText(head))).toBe(1000000)
  expect(windowOf('claude-sonnet-5-5')).toBe(200000)
  expect(shortModel('claude-opus-5-5[1m]')).toBe('opus')
})

test('line and marks: 58% plain, 60% warn, 70% red', async () => {
  const row = { id: 'x', label: 'A1 payroll-run', model: 'opus', tokens: 116000, win: 200000, isDone: false }
  expect(lineOf(row)).toBe('A1 payroll-run · opus · 58% (116k/200k)')
  expect(level(59)).toBe('ok')
  expect(level(60)).toBe('warn')
  expect(level(70)).toBe('red')
  expect(lineOf({ ...row, tokens: 140000 })).toBe('A1 payroll-run · opus · 70% (140k/200k) !! HANDOVER')
})
