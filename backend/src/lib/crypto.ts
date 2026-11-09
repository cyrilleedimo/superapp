// Primitives cryptographiques : hachage, jetons aléatoires, HMAC à temps constant.
import { createHash, createHmac, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';

export const sha256Hex = (s: string | Buffer) => createHash('sha256').update(s).digest('hex');

/** Jeton opaque URL-safe (256 bits d'entropie par défaut). */
export const randomToken = (bytes = 32) => randomBytes(bytes).toString('base64url');

/** Code OTP numérique à 6 chiffres, tiré par CSPRNG. */
export const otpCode = () => String(randomInt(0, 1_000_000)).padStart(6, '0');

export const hmacSha256Hex = (secret: string, payload: string | Buffer) =>
  createHmac('sha256', secret).update(payload).digest('hex');

/** Compare deux signatures hex sans fuite temporelle. */
export function safeEqualHex(a: string, b: string): boolean {
  if (!/^[0-9a-f]+$/i.test(a) || !/^[0-9a-f]+$/i.test(b)) return false;
  const ba = Buffer.from(a.toLowerCase(), 'hex');
  const bb = Buffer.from(b.toLowerCase(), 'hex');
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}
