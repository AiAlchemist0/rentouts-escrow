import { describe, expect, it } from 'vitest'
import { POLL_MS, walletReadQuery } from './polling'

describe('walletReadQuery', () => {
  it('polls balances and allowances, so an outside faucet top-up shows up without a reload', () => {
    expect(walletReadQuery(true)).toEqual({ enabled: true, refetchInterval: POLL_MS })
    expect(POLL_MS).toBeGreaterThan(0)
    expect(POLL_MS).toBeLessThanOrEqual(15_000)
  })

  it('stays off without a wallet', () => {
    expect(walletReadQuery(false).enabled).toBe(false)
  })
})
