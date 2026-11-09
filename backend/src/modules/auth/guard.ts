// preHandler Fastify : exige un jeton d'accès valide (et éventuellement un rôle).
import type { FastifyRequest } from 'fastify';
import type { Ctx, AuthUser } from '../../context.js';
import { forbidden, unauthorized } from '../../lib/errors.js';

export function requireAuth(ctx: Ctx, roles?: AuthUser['role'][]) {
  return async (req: FastifyRequest) => {
    const h = req.headers.authorization;
    if (!h?.startsWith('Bearer ')) throw unauthorized('missing_token');
    try {
      req.user = await ctx.tokens.verify(h.slice(7));
    } catch {
      throw unauthorized('invalid_token');
    }
    if (roles && !roles.includes(req.user.role)) throw forbidden();
  };
}

/** Raccourci typé : l'utilisateur est garanti après requireAuth. */
export const me = (req: FastifyRequest): AuthUser => {
  if (!req.user) throw unauthorized();
  return req.user;
};
