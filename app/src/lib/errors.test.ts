import {
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  encodeErrorResult,
  zeroAddress,
} from 'viem'
import { describe, expect, it } from 'vitest'
import { aiArbiterAbi } from '../abi/aiArbiter'
import { leaseShareAbi } from '../abi/leaseShare'
import { rentEscrowAbi } from '../abi/rentEscrow'
import { rentoutsSubnamesAbi } from '../abi/rentoutsSubnames'
import { describeError, errorMessage } from './errors'

const alice = '0x484811c8c967809bE644A89d677933c29fb9e936'

/** What simulateContract throws when `abi` is the ABI of the contract that was called. */
function revert(abi: typeof rentEscrowAbi | typeof rentoutsSubnamesAbi | typeof aiArbiterAbi, functionName: string, data: `0x${string}`) {
  return new ContractFunctionExecutionError(new ContractFunctionRevertedError({ abi, data, functionName }), {
    abi,
    functionName,
    args: [],
    contractAddress: zeroAddress,
  })
}

describe('describeError', () => {
  it('maps the claim-flow errors', () => {
    expect(describeError('LabelTaken', ['alice'])).toMatch(/taken/)
    expect(describeError('AlreadyHasName', [alice])).toMatch(/already holds/)
    expect(describeError('LabelRetired', ['bob'])).toMatch(/retired/)
    expect(describeError('InvalidLabel', ['-x'])).toMatch(/3–32/)
    expect(describeError('NotAuthorized')).toMatch(/connected wallet/)
  })

  it('names the lease state for InvalidState', () => {
    expect(describeError('InvalidState', [7n, 4])).toBe('Lease #7 is closed, so this action isn’t available.')
  })

  it('mentions the party rules for InvalidTerms', () => {
    expect(describeError('InvalidTerms')).toMatch(/arbiter can’t be the landlord or the tenant/)
  })

  it('explains the human gate for NotVerifiedHuman', () => {
    expect(describeError('NotVerifiedHuman', [alice])).toBe(
      '0x4848…e936 hasn’t passed the escrow’s human verification (World ID — coming soon), so it can’t fund a lease.',
    )
    expect(describeError('NotVerifiedHuman')).toMatch(/^This wallet hasn’t passed/)
  })

  it('explains the AI judge’s rules', () => {
    expect(describeError('NoOpenProposal', [3n, 2])).toBe('Lease #3 has no open AI proposal: it was appealed, so only the human arbiter can rule now.')
    expect(describeError('NoOpenProposal', [3n, 0])).toMatch(/hasn’t proposed a ruling yet/)
    expect(describeError('NotDisputed', [3n, 4])).toBe('Lease #3 is closed, not in dispute.')
    expect(describeError('PartyCannotArbitrate', [3n, alice])).toBe('0x4848…e936 is a party to lease #3, so it can’t rule on it.')
    expect(describeError('InvalidStatementLength', [0n])).toBe('Write a statement first.')
    expect(describeError('InvalidStatementLength', [1200n])).toMatch(/1,200 bytes/)
    expect(describeError('ChallengeWindowOver', [3n, 1n])).toMatch(/can’t be appealed any more/)
    expect(describeError('ChallengeWindowOpen', [3n, 1n])).toMatch(/hasn’t closed on-chain yet/)
    expect(describeError('NotHuman')).toBe('Only the human arbiter can do this.')
    expect(describeError('NotParty', [3n])).toBe('Only the landlord or the tenant of lease #3 can do this.')
  })

  it('falls back to the error name', () => {
    expect(describeError('SomethingNew')).toBe('The contract reverted with SomethingNew.')
  })
})

describe('errorMessage', () => {
  it('decodes a custom error on the called contract’s ABI', () => {
    const data = encodeErrorResult({ abi: rentoutsSubnamesAbi, errorName: 'LabelTaken', args: ['alice'] })
    expect(errorMessage(revert(rentoutsSubnamesAbi, 'register', data))).toBe('This name is taken. Pick another one.')
  })

  it('decodes an error bubbled up from another contract (LeaseShare1155 via the escrow)', () => {
    const data = encodeErrorResult({ abi: leaseShareAbi, errorName: 'NotAllowlisted', args: [alice] })
    expect(errorMessage(revert(rentEscrowAbi, 'createLease', data))).toMatch(/^0x4848…e936 isn’t on the lease-share compliance allowlist/)
  })

  it('decodes a NotVerifiedHuman revert from fundLease', () => {
    const data = encodeErrorResult({ abi: rentEscrowAbi, errorName: 'NotVerifiedHuman', args: [alice] })
    expect(errorMessage(revert(rentEscrowAbi, 'fundLease', data))).toMatch(/^0x4848…e936 hasn’t passed the escrow’s human verification/)
    // Also when the revert surfaces through a call whose ABI doesn't list it (decoded against knownErrorsAbi).
    expect(errorMessage(revert(rentoutsSubnamesAbi, 'register', data))).toMatch(/World ID — coming soon/)
  })

  it('decodes AIArbiter reverts, including the escrow’s bubbling through it', () => {
    const data = encodeErrorResult({ abi: aiArbiterAbi, errorName: 'TooManyStatements', args: [3n, alice] })
    expect(errorMessage(revert(aiArbiterAbi, 'submitEvidence', data))).toBe('You’ve used all 5 statements for this lease.')
    const escrowData = encodeErrorResult({ abi: rentEscrowAbi, errorName: 'InvalidState', args: [3n, 4] })
    expect(errorMessage(revert(aiArbiterAbi, 'execute', escrowData))).toBe('Lease #3 is closed, so this action isn’t available.')
  })

  it('passes through require() reasons', () => {
    const data = encodeErrorResult({
      abi: [{ type: 'error', name: 'Error', inputs: [{ name: 'message', type: 'string' }] }],
      errorName: 'Error',
      args: ['ERC20: transfer amount exceeds balance'],
    })
    expect(errorMessage(revert(rentEscrowAbi, 'fundLease', data))).toBe(
      'The contract reverted: ERC20: transfer amount exceeds balance',
    )
  })

  it('recognizes a wallet rejection', () => {
    expect(errorMessage(new UserRejectedRequestError(new Error('User denied')))).toBe(
      'You rejected the request in your wallet.',
    )
  })

  it('handles plain errors', () => {
    expect(errorMessage(new Error('boom'))).toBe('boom')
  })
})
