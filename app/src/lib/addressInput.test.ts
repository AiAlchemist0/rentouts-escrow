import { describe, expect, it } from 'vitest'
import { parseAddressInput, resolveAddressInput, type NameLookup } from './addressInput'

const alice = '0x484811c8c967809bE644A89d677933c29fb9e936'
const admin = '0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE'

const idle: NameLookup = { isPending: true, isError: false, error: null, data: undefined }
const resolvedTo = (address: `0x${string}`): NameLookup => ({ isPending: false, isError: false, error: null, data: address })

describe('parseAddressInput', () => {
  it('parses addresses, names and neither', () => {
    expect(parseAddressInput('')).toEqual({ kind: 'empty' })
    expect(parseAddressInput(` ${alice.toLowerCase()} `)).toEqual({ kind: 'address', address: alice })
    expect(parseAddressInput('Alice.Rentouts.eth')).toEqual({ kind: 'name', name: 'alice.rentouts.eth' })
    expect(parseAddressInput('alice')).toMatchObject({ kind: 'error' })
  })

  it('treats a claimable 0x-style label as a name', () => {
    expect(parseAddressInput('0xrent.rentouts.eth')).toEqual({ kind: 'name', name: '0xrent.rentouts.eth' })
    expect(parseAddressInput('0xjudge.rentouts.eth')).toEqual({ kind: 'name', name: '0xjudge.rentouts.eth' })
  })
})

describe('resolveAddressInput', () => {
  it('never returns the previously entered address while the debounce catches up', () => {
    // The field now shows a new address; the debounced value is still the old one.
    expect(resolveAddressInput(admin, alice, idle)).toEqual({ kind: 'address', address: admin })
    // The field now shows a name; the old address must not be sent.
    expect(resolveAddressInput('bob.rentouts.eth', alice, idle)).toEqual({ kind: 'pending' })
    // The field now shows another name; the old name's resolved address must not be sent.
    expect(resolveAddressInput('bob.rentouts.eth', 'alice.rentouts.eth', resolvedTo(alice))).toEqual({ kind: 'pending' })
  })

  it('does not flag half-typed text as an error before the debounce', () => {
    expect(resolveAddressInput('ali', '', idle)).toEqual({ kind: 'pending' })
    expect(resolveAddressInput('ali', 'ali', idle)).toMatchObject({ kind: 'error' })
  })

  it('resolves a name once the debounced value matches the field', () => {
    expect(resolveAddressInput('alice.rentouts.eth', 'alice.rentouts.eth', idle)).toEqual({
      kind: 'loading',
      name: 'alice.rentouts.eth',
    })
    expect(resolveAddressInput(' alice.rentouts.eth', 'alice.rentouts.eth', resolvedTo(alice))).toEqual({
      kind: 'name',
      name: 'alice.rentouts.eth',
      address: alice,
    })
    expect(
      resolveAddressInput('nobody.rentouts.eth', 'nobody.rentouts.eth', { isPending: false, isError: false, error: null, data: null }),
    ).toEqual({ kind: 'error', message: 'nobody.rentouts.eth doesn’t resolve to an address.' })
  })

  it('reports empty input as empty', () => {
    expect(resolveAddressInput('  ', alice, idle)).toEqual({ kind: 'empty' })
  })
})
