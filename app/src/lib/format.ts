import { formatUnits, parseUnits, type Address, type Hash } from 'viem'
import { ENS_APP, EXPLORER } from '../config'

export const USDC_DECIMALS = 6

/** Token units -> "1,234.50". Keeps at least 2 decimals and drops trailing zeros beyond that. */
export function formatToken(amount: bigint, decimals = USDC_DECIMALS): string {
  const negative = amount < 0n
  const [whole, fraction = ''] = formatUnits(negative ? -amount : amount, decimals).split('.')
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  const frac = fraction.replace(/0+$/, '').padEnd(2, '0')
  return `${negative ? '-' : ''}${grouped}.${frac}`
}

/** "0.25" -> 250000n for 6 decimals. Returns null for anything that isn't a plain non-negative decimal. */
export function parseToken(input: string, decimals = USDC_DECIMALS): bigint | null {
  const v = input.trim()
  if (!/^\d+(\.\d*)?$|^\.\d+$/.test(v)) return null
  const fraction = v.split('.')[1] ?? ''
  if (fraction.length > decimals) return null
  return parseUnits(v.startsWith('.') ? `0${v}` : v, decimals)
}

/** Parses a positive whole number no larger than `max`, or returns null. */
export function parseWhole(input: string, max: number): number | null {
  const v = input.trim()
  if (!/^\d+$/.test(v)) return null
  const n = Number(v)
  return Number.isSafeInteger(n) && n > 0 && n <= max ? n : null
}

export function shortAddress(address: string): string {
  return address.length > 12 ? `${address.slice(0, 6)}…${address.slice(-4)}` : address
}

/** 75 -> "1m 15s", 7260 -> "2h 1m". */
export function formatDuration(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds))
  const d = Math.floor(s / 86_400)
  const h = Math.floor((s % 86_400) / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  if (d > 0) return h > 0 ? `${d}d ${h}h` : `${d}d`
  if (h > 0) return m > 0 ? `${h}h ${m}m` : `${h}h`
  if (m > 0) return sec > 0 ? `${m}m ${sec}s` : `${m}m`
  return `${sec}s`
}

/** "12:05" style clock for countdowns under an hour, formatDuration beyond that. */
export function formatCountdown(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds))
  if (s >= 3600) return formatDuration(s)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

export const txUrl = (hash: Hash) => `${EXPLORER}/tx/${hash}`
export const addressUrl = (address: Address) => `${EXPLORER}/address/${address}`
export const ensAppUrl = (name: string) => `${ENS_APP}/${name}`
