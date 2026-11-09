// Routes commandes, paiements, webhooks et portefeuille.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { badRequest, parse } from '../../lib/errors.js';
import { me, requireAuth } from '../auth/guard.js';
import { balance, walletAccount } from '../ledger/ledger.js';
import { makeOrderService } from './service.js';

export async function orderRoutes(app: FastifyInstance, ctx: Ctx) {
  const orders = makeOrderService(ctx);
  const auth = { preHandler: requireAuth(ctx) };
  const idParam = z.object({ id: z.uuid() });

  // L'en-tête Idempotency-Key évite les doubles commandes (réseau mobile instable).
  app.post('/orders', auth, async (req, reply) => {
    const key = req.headers['idempotency-key'];
    if (typeof key !== 'string' || !/^[A-Za-z0-9_-]{16,64}$/.test(key)) throw badRequest('idempotency_key_required');
    const b = parse(z.object({ listingId: z.uuid() }), req.body);
    const out = await orders.create(me(req).id, b.listingId, key);
    return reply.code(out.replayed ? 200 : 201).send(out.order);
  });

  app.get('/orders', auth, async (req) => ({ items: await orders.listMine(me(req).id) }));
  app.get('/orders/:id', auth, async (req) => orders.get(me(req).id, parse(idParam, req.params).id));

  app.post('/orders/:id/pay', auth, async (req) => orders.startPayment(me(req).id, parse(idParam, req.params).id));
  app.post('/orders/:id/confirm', auth, async (req) => orders.confirmReceipt(me(req).id, parse(idParam, req.params).id));
  app.post('/orders/:id/cancel', auth, async (req) => orders.cancel(me(req).id, parse(idParam, req.params).id));
  app.post('/orders/:id/dispute', auth, async (req) => {
    const { reason } = parse(z.object({ reason: z.string().trim().min(10).max(1000) }), req.body);
    return orders.dispute(me(req).id, parse(idParam, req.params).id, reason);
  });
  app.post('/admin/orders/:id/refund', { preHandler: requireAuth(ctx, ['admin']) },
    async (req) => orders.refund(me(req).id, parse(idParam, req.params).id));

  app.post('/payments/:reference/refresh', auth, async (req) => {
    const { reference } = parse(z.object({ reference: z.string().regex(/^ord_[A-Za-z0-9_-]{8,40}$/) }), req.params);
    return orders.refreshPayment(me(req).id, reference);
  });

  // Webhook prestataire : pas d'authentification utilisateur, la signature HMAC fait foi.
  app.post('/webhooks/payments', { config: { rateLimit: { max: 120, timeWindow: '1 minute' } } }, async (req) => {
    if (!req.rawBody) throw badRequest('raw_body_missing');
    return orders.handleWebhook(req.rawBody, req.headers, req.body);
  });

  app.get('/me/wallet', auth, async (req) => {
    // Le portefeuille est une dette de la plateforme : solde créditeur (négatif) = disponible.
    const available = -(await balance(ctx.db, walletAccount(me(req).id)));
    return { currency: 'XAF', availableXaf: available };
  });
}
