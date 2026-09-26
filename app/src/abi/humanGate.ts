import { parseAbi } from 'viem'

/**
 * The human gate RentEscrow.fundLease consults (rentouts-escrow-core src/interfaces/IHumanGate.sol and
 * src/HumanGate.sol). HumanGate forwards isVerified to `verifier`; while that is address(0) the gate is open
 * and every account passes. On Sepolia the verifier is a WorldIdV4Gate (src/WorldIdV4Gate.sol, World ID 4.0).
 * verifier() exists on HumanGate only, so the app treats a failed read as "unknown".
 */
export const humanGateAbi = parseAbi([
  'function isVerified(address account) view returns (bool)',
  'function verifier() view returns (address)',
])
