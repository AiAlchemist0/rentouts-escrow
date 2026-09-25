import { useSyncExternalStore } from 'react'
import type { Hash } from 'viem'

/**
 * Session log of every transaction the app sent. Cards can unmount once their transaction lands (a
 * funded lease leaves the "waiting" list), so the Etherscan link lives here, not only in the card.
 */
export type TxEntry = { hash: Hash; label: string; status: 'pending' | 'success' | 'reverted' }

let entries: TxEntry[] = []
const listeners = new Set<() => void>()
const emit = () => listeners.forEach((l) => l())

export function recordTx(entry: TxEntry) {
  entries = [entry, ...entries.filter((e) => e.hash !== entry.hash)].slice(0, 8)
  emit()
}

export function useTxLog(): TxEntry[] {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    () => entries,
  )
}
