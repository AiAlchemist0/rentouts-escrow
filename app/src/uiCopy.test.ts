import { describe, expect, it } from 'vitest'

/** Every UI source file, as text. */
const sources = import.meta.glob<string>('./**/*.tsx', { query: '?raw', import: 'default', eager: true })

describe('UI copy', () => {
  it('never names the judge model: nothing the page reads on-chain records which model proposed a ruling', () => {
    expect(Object.keys(sources).length).toBeGreaterThan(5)
    for (const [file, text] of Object.entries(sources)) expect(text, file).not.toMatch(/\bGLM\b/i)
  })
})
