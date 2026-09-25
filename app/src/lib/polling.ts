/** How often live chain state is re-read: about one Sepolia block. */
export const POLL_MS = 12_000

/**
 * Query options for a wallet read that can change outside this app (a faucet top-up in another tab, a transfer).
 * Polled, because window-focus refetching is off (main.tsx) and only this app's own confirmed transactions
 * invalidate queries: without it a tenant who approves, then uses a faucet, can never press Fund.
 */
export function walletReadQuery(enabled: boolean) {
  return { enabled, refetchInterval: POLL_MS } as const
}
