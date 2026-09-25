import { describe, expect, it } from 'vitest'
import { asAddress, parseDeployments, resolveContracts } from './deployments'

// The shapes script/DeployEscrow.s.sol and script/DeployAIArbiter.s.sol write (addresses lower-cased, as vm.serializeAddress does).
const file = {
  baseSepolia: { chainId: 84532, LeaseShare1155: { address: '0x5490e5dFcDcA741aC99127f66B4abf6204cd64C5' } },
  sepolia: {
    chainId: 11155111,
    deployer: '0xdd9c17ecae9301b67de17f1ba2b5084eac59ccce',
    token: '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238',
    arbiter: '0x3333333333333333333333333333333333333333',
    humanGate: '0x4444444444444444444444444444444444444444',
    leaseShare1155: '0x5555555555555555555555555555555555555555',
    rentEscrow: '0x6666666666666666666666666666666666666666',
  },
  sepoliaAIArbiter: {
    chainId: 11155111,
    deployer: '0xdd9c17ecae9301b67de17f1ba2b5084eac59ccce',
    human: '0x798b01cef62b889943ce1d3c5011a755b297e486',
    agent: '0x4a444685f3e700d0d5b8fe53d987f8029cced0da',
    challengeWindow: 120,
    fromBlock: 11800000,
    aiArbiter: '0x3333333333333333333333333333333333333333',
  },
}

describe('asAddress', () => {
  it('checksums valid addresses and drops everything else', () => {
    expect(asAddress('0x1c7d4b196cb0c7b01d743fbc6116a902379c7238')).toBe('0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238')
    expect(asAddress(' 0x1c7d4b196cb0c7b01d743fbc6116a902379c7238 ')).toBe('0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238')
    expect(asAddress('0x0000000000000000000000000000000000000000')).toBeUndefined()
    expect(asAddress('0x1234')).toBeUndefined()
    expect(asAddress(42)).toBeUndefined()
    expect(asAddress(undefined)).toBeUndefined()
  })
})

describe('parseDeployments', () => {
  it('reads both script entries', () => {
    expect(parseDeployments(file)).toEqual({
      rentEscrow: '0x6666666666666666666666666666666666666666',
      leaseShare1155: '0x5555555555555555555555555555555555555555',
      humanGate: '0x4444444444444444444444444444444444444444',
      token: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
      arbiter: '0x3333333333333333333333333333333333333333',
      aiArbiter: '0x3333333333333333333333333333333333333333',
      aiFromBlock: 11_800_000n,
    })
  })

  it('degrades to nothing when the file or an entry is missing', () => {
    const empty = parseDeployments(undefined)
    expect(Object.values(empty).every((v) => v === undefined)).toBe(true)
    expect(parseDeployments({ baseSepolia: file.baseSepolia }).rentEscrow).toBeUndefined()
    expect(parseDeployments({ sepolia: file.sepolia }).aiArbiter).toBeUndefined()
    expect(parseDeployments({ sepoliaAIArbiter: file.sepoliaAIArbiter }).rentEscrow).toBeUndefined()
    expect(parseDeployments('nope').rentEscrow).toBeUndefined()
    expect(parseDeployments([file]).rentEscrow).toBeUndefined()
  })

  it('ignores entries for another chain and malformed values', () => {
    expect(parseDeployments({ sepolia: { ...file.sepolia, chainId: 84532 } }).rentEscrow).toBeUndefined()
    const bad = parseDeployments({ sepolia: { ...file.sepolia, rentEscrow: 'not an address' }, sepoliaAIArbiter: { ...file.sepoliaAIArbiter, fromBlock: -5 } })
    expect(bad.rentEscrow).toBeUndefined()
    expect(bad.leaseShare1155).toBe('0x5555555555555555555555555555555555555555')
    expect(bad.aiFromBlock).toBeUndefined()
    expect(parseDeployments({ sepoliaAIArbiter: { ...file.sepoliaAIArbiter, fromBlock: '12' } }).aiFromBlock).toBe(12n)
  })
})

describe('resolveContracts', () => {
  const deployed = parseDeployments(file)
  const other = '0x7777777777777777777777777777777777777777'

  it('uses deployments.json when no env var is set', () => {
    expect(resolveContracts({}, deployed)).toEqual({
      escrow: deployed.rentEscrow,
      leaseShare: deployed.leaseShare1155,
      token: deployed.token,
      humanGate: deployed.humanGate,
      arbiter: deployed.arbiter,
      aiArbiter: deployed.aiArbiter,
      aiFromBlock: 11_800_000n,
    })
  })

  it('lets VITE_* env vars win', () => {
    const r = resolveContracts({ leaseShare: other, token: other, aiArbiter: other }, deployed)
    expect(r).toMatchObject({ escrow: deployed.rentEscrow, leaseShare: other, token: other, aiArbiter: other })
    // fromBlock belongs to the recorded AIArbiter only
    expect(r.aiFromBlock).toBeUndefined()
  })

  it('drops the recorded escrow’s satellites when the env points at another escrow', () => {
    const r = resolveContracts({ escrow: other }, deployed)
    expect(r).toMatchObject({ escrow: other, leaseShare: undefined, token: undefined, humanGate: undefined, arbiter: undefined })
    expect(r.aiArbiter).toBe(deployed.aiArbiter)
    // …but keeps them when the env names the recorded escrow itself
    expect(resolveContracts({ escrow: deployed.rentEscrow }, deployed).humanGate).toBe(deployed.humanGate)
  })

  it('is empty with nothing deployed and nothing set', () => {
    expect(Object.values(resolveContracts({}, parseDeployments(undefined))).every((v) => v === undefined)).toBe(true)
  })
})
