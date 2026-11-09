// Routes /auth/* et /me. Limitation de débit renforcée sur les routes sensibles.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { notFound, parse } from '../../lib/errors.js';
import { makeAuthService } from './service.js';
import { me, requireAuth } from './guard.js';

const phone = z.string().regex(/^\+[1-9][0-9]{7,14}$/, 'format E.164 attendu, ex. +2376XXXXXXXX');
const password = z.string().min(10, '10 caractères minimum').max(128);

const strict = { config: { rateLimit: { max: 10, timeWindow: '1 minute' } } };

export async function authRoutes(app: FastifyInstance, ctx: Ctx) {
  const auth = makeAuthService(ctx);
  const ua = (h: unknown) => (typeof h === 'string' ? h.slice(0, 200) : undefined);

  app.post('/auth/register', strict, async (req, reply) => {
    const body = parse(z.object({
      phone, password,
      displayName: z.string().trim().min(2).max(60),
      email: z.email().optional(),
    }), req.body);
    const out = await auth.register(body, req.ip);
    return reply.code(201).send({ userId: out.userId, next: 'verify_phone' });
  });

  app.post('/auth/resend-otp', strict, async (req, reply) => {
    const { phone: p } = parse(z.object({ phone }), req.body);
    await auth.resendOtp(p);
    return reply.code(202).send({ ok: true });
  });

  app.post('/auth/verify-phone', strict, async (req) => {
    const b = parse(z.object({ phone, code: z.string().regex(/^\d{6}$/) }), req.body);
    return auth.verifyPhone(b.phone, b.code, ua(req.headers['user-agent']));
  });

  app.post('/auth/login', strict, async (req) => {
    const b = parse(z.object({ phone, password: z.string().min(1).max(128) }), req.body);
    return auth.login(b.phone, b.password, req.ip, ua(req.headers['user-agent']));
  });

  app.post('/auth/refresh', strict, async (req) => {
    const b = parse(z.object({ refreshToken: z.string().min(20).max(200) }), req.body);
    return auth.refresh(b.refreshToken, ua(req.headers['user-agent']));
  });

  app.post('/auth/logout', async (req, reply) => {
    const b = parse(z.object({ refreshToken: z.string().min(20).max(200) }), req.body);
    await auth.logout(b.refreshToken);
    return reply.code(204).send();
  });

  app.get('/me', { preHandler: requireAuth(ctx) }, async (req) => {
    const r = await ctx.db.query(
      `SELECT id, phone, email, display_name AS "displayName", role, status, created_at AS "createdAt"
       FROM users WHERE id=$1`, [me(req).id]);
    if (!r.rows[0]) throw notFound();
    return r.rows[0];
  });
}
