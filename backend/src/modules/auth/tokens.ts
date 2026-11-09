// Jetons d'accès JWT courts (15 min) signés HS256 + vérification stricte.
import { SignJWT, jwtVerify } from 'jose';
import type { AuthUser } from '../../context.js';

const ISSUER = 'superapp-api';
const AUDIENCE = 'superapp-client';

export function makeTokenService(secret: string, ttlSec: number) {
  const key = new TextEncoder().encode(secret);
  return {
    async sign(u: AuthUser): Promise<string> {
      return new SignJWT({ role: u.role })
        .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
        .setSubject(u.id)
        .setIssuer(ISSUER)
        .setAudience(AUDIENCE)
        .setIssuedAt()
        .setExpirationTime(`${ttlSec}s`)
        .sign(key);
    },
    async verify(token: string): Promise<AuthUser> {
      const { payload } = await jwtVerify(token, key, {
        issuer: ISSUER,
        audience: AUDIENCE,
        algorithms: ['HS256'], // refuse « none » et tout autre algorithme
      });
      if (!payload.sub) throw new Error('sub manquant');
      return { id: payload.sub, role: payload.role as AuthUser['role'] };
    },
  };
}
export type TokenService = ReturnType<typeof makeTokenService>;
