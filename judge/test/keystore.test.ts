import { execFileSync } from 'node:child_process'
import { createCipheriv, pbkdf2Sync, randomBytes, scryptSync } from 'node:crypto'
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { concat, hexToBytes, keccak256, type Hex } from 'viem'
import { generatePrivateKey, privateKeyToAddress } from 'viem/accounts'
import { describe, expect, it } from 'vitest'
import { decryptKeystore, keystorePath, KeystoreError } from '../src/keystore.ts'
import { truncateUtf8 } from '../src/propose.ts'

/** Encrypts a THROWAWAY test key in the v3 format (cheap KDF parameters). */
function encrypt(pk: Hex, password: string, kdf: 'scrypt' | 'pbkdf2') {
  const salt = randomBytes(32)
  const iv = randomBytes(16)
  const dk =
    kdf === 'scrypt' ? scryptSync(password, salt, 32, { N: 1024, r: 8, p: 1 }) : pbkdf2Sync(password, salt, 1000, 32, 'sha256')
  const cipher = createCipheriv('aes-128-ctr', dk.subarray(0, 16), iv)
  const ciphertext = Buffer.concat([cipher.update(hexToBytes(pk)), cipher.final()])
  const mac = keccak256(concat([dk.subarray(16, 32), ciphertext])).slice(2)
  const kdfparams =
    kdf === 'scrypt'
      ? { dklen: 32, n: 1024, r: 8, p: 1, salt: salt.toString('hex') }
      : { dklen: 32, c: 1000, prf: 'hmac-sha256', salt: salt.toString('hex') }
  return {
    version: 3,
    id: '00000000-0000-4000-8000-000000000000',
    crypto: { cipher: 'aes-128-ctr', cipherparams: { iv: iv.toString('hex') }, ciphertext: ciphertext.toString('hex'), kdf, kdfparams, mac },
  }
}

function hasCast(): boolean {
  try {
    execFileSync('cast', ['--version'], { stdio: 'ignore' })
    return true
  } catch {
    return false
  }
}

describe('keystore (Web3 Secret Storage v3)', () => {
  for (const kdf of ['scrypt', 'pbkdf2'] as const) {
    it(`decrypts a ${kdf} keystore and refuses a wrong password`, () => {
      const pk = generatePrivateKey()
      const ks = encrypt(pk, 'correct horse', kdf)
      expect(decryptKeystore(ks, 'correct horse')).toBe(pk)
      expect(() => decryptKeystore(ks, 'wrong')).toThrow(KeystoreError)
      expect(() => decryptKeystore(ks, 'wrong')).toThrow(/MAC mismatch/)
    })
  }

  it('refuses things that are not a v3 aes-128-ctr keystore', () => {
    expect(() => decryptKeystore({ version: 1 }, 'x')).toThrow(/not a v3/)
    expect(() => decryptKeystore('0xabc', 'x')).toThrow(/not a v3/)
  })

  it('keystore names are plain file names under ~/.foundry/keystores', () => {
    expect(keystorePath('rentouts-judge')).toMatch(/\.foundry\/keystores\/rentouts-judge$/)
    expect(keystorePath('judge', '/tmp/ks')).toBe('/tmp/ks/judge')
    expect(() => keystorePath('../../etc/passwd')).toThrow(/invalid keystore name/)
  })

  it.skipIf(!hasCast())('reads a keystore written by `cast wallet new` (throwaway key)', () => {
    const dir = mkdtempSync(join(tmpdir(), 'judge-ks-'))
    try {
      execFileSync('cast', ['wallet', 'new', dir, '--unsafe-password', 'throwaway'], { stdio: 'ignore' })
      const file = readdirSync(dir)[0]!
      const address = execFileSync(
        'cast',
        ['wallet', 'address', '--keystore', join(dir, file), '--password', 'throwaway'],
        { encoding: 'utf8' },
      ).trim()
      const pk = decryptKeystore(JSON.parse(readFileSync(join(dir, file), 'utf8')), 'throwaway')
      expect(privateKeyToAddress(pk)).toBe(address)
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})

describe('truncateUtf8 (AIArbiter summary <= 1000 bytes)', () => {
  it('keeps short text and cuts long text on a character boundary', () => {
    expect(truncateUtf8('short', 1000)).toBe('short')
    const long = '窓'.repeat(400) // 1200 bytes
    const cut = truncateUtf8(long, 1000)
    expect(new TextEncoder().encode(cut).length).toBeLessThanOrEqual(1000)
    expect(cut.endsWith('...')).toBe(true)
    expect(cut.startsWith('窓窓')).toBe(true)
  })
})
