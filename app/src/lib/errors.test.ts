import {
  ContractFunctionExecutionError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  encodeErrorResult,
  zeroAddress,
} from 'viem'
import { describe, expect, it } from 'vitest'
import { leaseShareAbi } from '../abi/leaseShare'
import { rentEscrowAbi } from '../abi/rentEscrow'
import { rentoutsSubnamesAbi } from '../abi/rentoutsSubnames'
import { describeError, errorMessage } from './errors'

const alice = '0x484811c8c967809bE644A89d677933c29fb9e936'

/** What simulateContract throws when `abi` is the ABI of the contract that was called. */
function revert(abi: typeof rentEscrowAbi | typeof rentoutsSubnamesAbi, functionName: string, data: `0x${string}`) {
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
