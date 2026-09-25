import { createDecipheriv, pbkdf2Sync, scryptSync, timingSafeEqual } from 'node:crypto'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { concat, hexToBytes, keccak256, toHex } from 'viem'
import { z } from 'zod'
import type { Hex } from './types.ts'

/**
 * Decrypts a Web3 Secret Storage v3 keystore, the format `cast wallet import` / `cast wallet new`
 * write to ~/.foundry/keystores/<name> (scrypt or pbkdf2 + aes-128-ctr, keccak MAC). The private
 * key only lives in memory long enough to build a viem account; it is never logged or written.
 */
const hex = z.string().regex(/^(0x)?[0-9a-fA-F]*$/)
const KeystoreSchema = z.object({
  version: z.literal(3),
  crypto: z.object({
    cipher: z.literal('aes-128-ctr'),
    cipherparams: z.object({ iv: hex }),
    ciphertext: hex,
    kdf: z.enum(['scrypt', 'pbkdf2']),
    kdfparams: z.record(z.string(), z.union([z.number(), z.string()])),
    mac: hex,
  }),
})

const bytes = (h: string) => hexToBytes((h.startsWith('0x') ? h : `0x${h}`) as Hex)

export class KeystoreError extends Error {
  name = 'KeystoreError'
}

/** ~/.foundry/keystores/<name>, or <dir>/<name> when a directory is given (JUDGE_KEYSTORE_DIR). */
export function keystorePath(name: string, dir?: string): string {
  if (!/^[A-Za-z0-9._-]+$/.test(name)) throw new KeystoreError(`invalid keystore name "${name}"`)
  return join(dir || join(homedir(), '.foundry', 'keystores'), name)
}

export function decryptKeystore(json: unknown, password: string): Hex {
  const parsed = KeystoreSchema.safeParse(
    typeof json === 'object' && json !== null && 'Crypto' in json && !('crypto' in json)
      ? { ...json, crypto: (json as { Crypto: unknown }).Crypto }
      : json,
  )
  if (!parsed.success) throw new KeystoreError('not a v3 aes-128-ctr keystore')
  const c = parsed.data.crypto
  const p = c.kdfparams
  const salt = bytes(String(p.salt))
  const dklen = Number(p.dklen)
  let key: Buffer
  if (c.kdf === 'scrypt') {
    const N = Number(p.n)
    const r = Number(p.r)
    key = scryptSync(password, salt, dklen, { N, r, p: Number(p.p), maxmem: 256 * N * r + 32 * 1024 * 1024 })
  } else {
    if (p.prf !== 'hmac-sha256') throw new KeystoreError(`unsupported pbkdf2 prf ${String(p.prf)}`)
    key = pbkdf2Sync(password, salt, Number(p.c), dklen, 'sha256')
  }
  const ciphertext = bytes(c.ciphertext)
  const mac = hexToBytes(keccak256(concat([key.subarray(16, 32), ciphertext])))
  const expected = bytes(c.mac)
  if (expected.length !== mac.length || !timingSafeEqual(mac, expected)) {
    throw new KeystoreError('wrong keystore password (MAC mismatch)')
  }
  const decipher = createDecipheriv('aes-128-ctr', key.subarray(0, 16), bytes(c.cipherparams.iv))
  const pk = Buffer.concat([decipher.update(ciphertext), decipher.final()])
  if (pk.length !== 32) throw new KeystoreError('decrypted key is not 32 bytes')
  return toHex(pk)
}

/** Reads a password from the terminal without echoing it. */
export async function promptHidden(question: string): Promise<string> {
  const stdin = process.stdin
  if (!stdin.isTTY) throw new KeystoreError('no terminal for the password prompt: set JUDGE_KEYSTORE_PASSWORD')
  process.stderr.write(question)
  stdin.setRawMode(true)
  stdin.resume()
  stdin.setEncoding('utf8')
  return new Promise((resolve, reject) => {
    let value = ''
    const done = (err?: Error) => {
      stdin.setRawMode(false)
      stdin.pause()
      stdin.removeListener('data', onData)
      process.stderr.write('\n')
      if (err) reject(err)
      else resolve(value)
    }
    const onData = (chunk: string) => {
      for (const ch of chunk) {
        if (ch === '\r' || ch === '\n' || ch === '\u0004') return done()
        if (ch === '\u0003') return done(new KeystoreError('cancelled'))
        if (ch === '\u007f' || ch === '\b') value = value.slice(0, -1)
        else value += ch
      }
    }
    stdin.on('data', onData)
  })
}
