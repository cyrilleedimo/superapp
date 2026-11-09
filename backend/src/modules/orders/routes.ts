// Routes commandes, paiements, webhooks et portefeuille (tous services confondus).
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { badRequest, parse } from '../../lib/errors.js';
import { me, requireAuth } from '../auth/guard.js';
import { balance, walletAccount } from '../ledger/ledger.js';
import type { OrderService } from './service.js';

/** L'en-tête Idempotency-Key évite les doubles commandes (réseau mobile instable). */
export function idempotencyKey(req: FastifyRequest): string {
  const key = req.headers['idempotency-key'];
  if (typeof key !== 'string' || !/^[A-Za-z0-9_-]{16,64}$/.test(key)) throw badRequest('idempotency_key_required');
  return key;
}

export async function orderRoutes(app: FastifyInstance, ctx: Ctx, orders: OrderService) {
  const auth = { preHandler: requireAuth(ctx) };
  const admin = { preHandler: requireAuth(ctx, ['admin']) };
  const idParam = z.object({ id: z.uuid() });

  app.post('/orders', auth, async (req, reply) => {
    const b = parse(z.object({ listingId: z.uuid(), offerId: z.uuid().optional() }), req.body);
    const out = await orders.createListingOrder(me(req).id, b.listingId, idempotencyKey(req), b.offerId);
    return reply.code(out.replayed ? 200 : 201).send(out.order);
  });

  app.get('/orders', auth, async (req) => {
    const q = parse(z.object({ role: z.enum(['buyer', 'seller', 'all']).default('all') }), req.query);
    return { items: await orders.listMine(me(req).id, q.role) };
  });
  app.get('/orders/:id', auth, async (req) => orders.get(me(req).id, parse(idParam, req.params).id));

  app.post('/orders/:id/pay', auth, async (req) => orders.startPayment(me(req).id, parse(idParam, req.params).id));
  app.post('/orders/:id/confirm', auth, async (req) => orders.confirmReceipt(me(req).id, parse(idParam, req.params).id));
  app.post('/orders/:id/cancel', auth, async (req) => orders.cancel(me(req).id, parse(idParam, req.params).id));
  app.post('/orders/:id/dispute', auth, async (req) => {
    const { reason } = parse(z.object({ reason: z.string().trim().min(10).max(1000) }), req.body);
    return orders.dispute(me(req).id, parse(idParam, req.params).id, reason);
  });
  app.post('/orders/:id/fulfillment', auth, async (req) => {
    const { step } = parse(z.object({ step: z.enum(['accepted', 'preparing', 'ready', 'delivering', 'delivered']) }), req.body);
    return orders.setFulfillment(me(req).id, parse(idParam, req.params).id, step);
  });

  app.post('/admin/orders/:id/refund', admin, async (req) => orders.refund(me(req).id, parse(idParam, req.params).id));
  app.post('/admin/orders/:id/release', admin, async (req) => orders.adminRelease(me(req).id, parse(idParam, req.params).id));
  app.get('/admin/disputes', admin, async () => {
    const r = await ctx.db.query(
      `SELECT o.id, o.kind, o.total_xaf AS "totalXaf", o.updated_at AS "updatedAt",
              (SELECT meta->>'reason' FROM audit_log a WHERE a.entity_id = o.id::text AND a.action='order.disputed'
               ORDER BY a.id DESC LIMIT 1) AS reason
       FROM orders o WHERE o.status='disputed' ORDER BY o.updated_at`);
    return { items: r.rows };
  });

  app.post('/payments/:reference/refresh', auth, async (req) => {
    const { reference } = parse(z.object({ reference: z.string().regex(/^ord_[A-Za-z0-9_-]{8,40}$/) }), req.params);
    return orders.refreshPayment(me(req).id, reference);
  });

  // Webhook prestataire : pas d'authentification utilisateur, la signature HMAC fait foi.
  app.post('/webhooks/payments', { config: { rateLimit: { max: 120, timeWindow: '1 minute' } } }, async (req) => {
    if (!req.rawBody) throw badRequest('raw_body_missing');
    return orders.handleWebhook(req.rawBody, req.headers, req.body);
  });

  // Page de retour après paiement (le navigateur y revient) : simple, sans données sensibles.
  app.get('/payments/return', async (_req, reply) =>
    reply.type('text/html; charset=utf-8').send(
      '<!doctype html><meta name="viewport" content="width=device-width"><title>Paiement</title>' +
      '<body style="font-family:system-ui;padding:32px;text-align:center"><h2>Merci !</h2>' +
      '<p>Retourne dans l\'application pour voir la confirmation de ton paiement.</p></body>'));

  app.get('/me/wallet', auth, async (req) => {
    // Le portefeuille est une dette de la plateforme : solde créditeur (négatif) = disponible.
    const available = -(await balance(ctx.db, walletAccount(me(req).id)));
    return { currency: 'XAF', availableXaf: available };
  });
}
