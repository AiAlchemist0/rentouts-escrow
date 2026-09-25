import type { Address } from 'viem'

export const HUMAN_GATE_TITLE = 'Human verification required (World ID — coming soon)'

/** What the app knows about RentEscrow.humanGate() for the connected tenant. */
export type HumanGateView = {
  /** The gate fundLease consults; undefined when funding isn't gated (or the escrow hasn't been read). */
  gate?: Address
  /** gate.isVerified(tenant); undefined while loading, without a wallet, or if the read failed. */
  verified?: boolean
  /** HumanGate.verifier() == address(0), so every account passes; undefined if unknown. */
  open?: boolean
}

export type HumanGateNotice = {
  tone: 'info' | 'error'
  title: string
  detail: string
  /** fundLease would revert NotVerifiedHuman for this wallet, so approving is pointless. */
  blocksFunding: boolean
}

const WHAT = 'The escrow asks a human gate whether a tenant is a verified human before it accepts funding.'

/** The notice the fund step shows, or null when the escrow has no human gate. */
export function humanGateNotice({ gate, verified, open }: HumanGateView): HumanGateNotice | null {
  if (!gate) return null
  const notice = (tone: HumanGateNotice['tone'], detail: string, blocksFunding = false): HumanGateNotice => ({
    tone,
    title: HUMAN_GATE_TITLE,
    detail: `${WHAT} ${detail}`,
    blocksFunding,
  })
  if (verified === false) {
    return notice(
      'error',
      'This wallet hasn’t passed it, so funding would revert. Verifying with World ID isn’t in this demo yet.',
      true,
    )
  }
  if (open) return notice('info', 'No verifier is plugged in on this testnet deployment yet, so every wallet passes for now.')
  if (verified) return notice('info', 'This wallet passes it.')
  return notice('info', 'Funding reverts for a wallet that doesn’t pass it.')
}
