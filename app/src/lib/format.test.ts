import { describe, expect, it } from 'vitest'
import { formatCountdown, formatDuration, formatToken, parseToken, parseWhole, shortAddress, tokenMetaFrom } from './format'
import { leasePartyProblem, leaseTiming, totalDue } from './lease'

describe('USDC formatting (6 decimals)', () => {
  it('formats token units', () => {
    expect(formatToken(0n)).toBe('0.00')
    expect(formatToken(250_000n)).toBe('0.25')
    expect(formatToken(1_000_000n)).toBe('1.00')
    expect(formatToken(1_234_567_890n)).toBe('1,234.56789')
    expect(formatToken(1n)).toBe('0.000001')
  })

  it('parses decimal input', () => {
    expect(parseToken('0.25')).toBe(250_000n)
    expect(parseToken('1')).toBe(1_000_000n)
    expect(parseToken('.5')).toBe(500_000n)
    expect(parseToken('0.000001')).toBe(1n)
  })

  it('rejects malformed or over-precise input', () => {
    for (const v of ['', 'abc', '-1', '1e6', '0.0000001', '1,000', '1.2.3']) expect(parseToken(v), v).toBeNull()
  })

  it('round-trips', () => {
    expect(parseToken(formatToken(850_000n))).toBe(850_000n)
  })
})

describe('other formatters', () => {
  it('parses whole numbers in range', () => {
    expect(parseWhole('120', 2 ** 32 - 1)).toBe(120)
    expect(parseWhole('0', 10)).toBeNull()
    expect(parseWhole('11', 10)).toBeNull()
    expect(parseWhole('1.5', 10)).toBeNull()
  })

  it('shortens addresses', () => {
    expect(shortAddress('0x484811c8c967809bE644A89d677933c29fb9e936')).toBe('0x4848…e936')
  })

  it('formats durations and countdowns', () => {
    expect(formatDuration(120)).toBe('2m')
    expect(formatDuration(75)).toBe('1m 15s')
    expect(formatDuration(7260)).toBe('2h 1m')
    expect(formatCountdown(65)).toBe('1:05')
    expect(formatCountdown(-3)).toBe('0:00')
  })
})

describe('lease timing', () => {
  const terms = { startTime: 1_000n, periodSeconds: 120, periods: 3, periodsClaimed: 0 }

  it('is null before funding', () => {
    expect(leaseTiming({ ...terms, startTime: 0n }, 5_000)).toBeNull()
  })

  it('tracks elapsed periods and the next unlock', () => {
    expect(leaseTiming(terms, 1_000)).toMatchObject({ elapsed: 0, nextUnlock: 1_120, ended: false })
    expect(leaseTiming(terms, 1_250)).toMatchObject({ elapsed: 2, nextUnlock: 1_360, ended: false })
    expect(leaseTiming(terms, 1_360)).toMatchObject({ elapsed: 3, nextUnlock: null, ended: true, end: 1_360 })
    expect(leaseTiming(terms, 9_999)).toMatchObject({ elapsed: 3, publicCloseAt: 1_480 })
  })

  it('totals deposit plus prepaid rent', () => {
    expect(totalDue(250_000n, 200_000n, 3)).toBe(850_000n)
  })
})

describe('lease parties (RentEscrow.createLease InvalidTerms rules)', () => {
  const landlord = '0x484811c8c967809bE644A89d677933c29fb9e936'
  const tenant = '0xF6048B190D178Fb6F0870c65CD2F7E06381713C4'
  const arbiter = '0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE'

  it('accepts distinct landlord, tenant and arbiter', () => {
    expect(leasePartyProblem(landlord, tenant, arbiter)).toBeNull()
    expect(leasePartyProblem(landlord, undefined, arbiter)).toBeNull()
    expect(leasePartyProblem(landlord, tenant, undefined)).toBeNull()
  })

  it('rejects a self-lease', () => {
    expect(leasePartyProblem(landlord, landlord.toLowerCase() as `0x${string}`, arbiter)).toMatch(/own wallet/)
  })

  it('rejects the arbiter as landlord or tenant', () => {
    expect(leasePartyProblem(arbiter, tenant, arbiter)).toMatch(/arbiter can’t be the landlord or the tenant/)
    expect(leasePartyProblem(arbiter, undefined, arbiter)).toMatch(/arbiter/)
    expect(leasePartyProblem(landlord, arbiter.toLowerCase() as `0x${string}`, arbiter)).toMatch(/arbiter/)
  })
})

describe('tokenMetaFrom', () => {
  const usdc = '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238'
  const ok = <T,>(value: T): PromiseSettledResult<T> => ({ status: 'fulfilled', value })
  const failed = (reason: unknown): PromiseSettledResult<never> => ({ status: 'rejected', reason })

  it('uses what the token reports', () => {
    expect(tokenMetaFrom(usdc, ok(6), ok('USDC'))).toEqual({ decimals: 6, symbol: 'USDC' })
    expect(tokenMetaFrom(usdc, ok(18), ok('WETH'))).toEqual({ decimals: 18, symbol: 'WETH' })
  })

  it('keeps decimals when only symbol() fails, labelling the token by address', () => {
    expect(tokenMetaFrom(usdc, ok(18), failed(new Error('symbol reverted')))).toEqual({ decimals: 18, symbol: '0x1c7D…7238' })
    expect(tokenMetaFrom(usdc, ok(18), ok(' '))).toEqual({ decimals: 18, symbol: '0x1c7D…7238' })
  })

  it('refuses to guess decimals', () => {
    const reason = new Error('decimals reverted')
    expect(() => tokenMetaFrom(usdc, failed(reason), ok('USDC'))).toThrow(reason)
  })
})
