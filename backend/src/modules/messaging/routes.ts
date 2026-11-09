// Messagerie acheteur ↔ vendeur autour d'une annonce, et offres de prix.
// Une offre acceptée permet ensuite d'acheter au prix négocié (POST /orders + offerId).
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { withTx } from '../../db.js';
import { conflict, forbidden, notFound, parse } from '../../lib/errors.js';
import { notify } from '../../lib/notify.js';
import { me, requireAuth } from '../auth/guard.js';

export async function messagingRoutes(app: FastifyInstance, ctx: Ctx) {
  const { db } = ctx;
  const auth = { preHandler: requireAuth(ctx) };
  const idParam = z.object({ id: z.uuid() });

  async function memberConv(convId: string, userId: string) {
    const r = await db.query<{ id: string; buyer_id: string; seller_id: string; listing_id: string }>(
      'SELECT id, buyer_id, seller_id, listing_id FROM conversations WHERE id=$1', [convId]);
    const c = r.rows[0];
    if (!c || (c.buyer_id !== userId && c.seller_id !== userId)) throw notFound();
    return c;
  }

  // Ouvre (ou retrouve) la conversation de l'acheteur sur une annonce.
  app.post('/conversations', auth, async (req, reply) => {
    const { listingId } = parse(z.object({ listingId: z.uuid() }), req.body);
    const userId = me(req).id;
    const l = await db.query<{ seller_id: string; status: string }>('SELECT seller_id, status FROM listings WHERE id=$1', [listingId]);
    const listing = l.rows[0];
    if (!listing || listing.status === 'removed') throw notFound('listing_not_found');
    if (listing.seller_id === userId) throw forbidden('own_listing');
    const r = await db.query<{ id: string }>(
      `INSERT INTO conversations (listing_id, buyer_id, seller_id) VALUES ($1,$2,$3)
       ON CONFLICT (listing_id, buyer_id) DO UPDATE SET listing_id = EXCLUDED.listing_id RETURNING id`,
      [listingId, userId, listing.seller_id]);
    return reply.code(201).send({ id: r.rows[0]!.id });
  });

  app.get('/conversations', auth, async (req) => {
    const userId = me(req).id;
    const r = await db.query(
      `SELECT c.id, c.listing_id AS "listingId", l.title AS "listingTitle", l.price_xaf AS "listingPriceXaf",
              CASE WHEN c.buyer_id=$1 THEN s.display_name ELSE b.display_name END AS "otherName",
              (c.buyer_id=$1) AS "iAmBuyer", c.last_message_at AS "lastMessageAt",
              (SELECT body FROM messages m WHERE m.conversation_id=c.id ORDER BY m.id DESC LIMIT 1) AS "lastMessage"
       FROM conversations c JOIN listings l ON l.id=c.listing_id
       JOIN users b ON b.id=c.buyer_id JOIN users s ON s.id=c.seller_id
       WHERE c.buyer_id=$1 OR c.seller_id=$1 ORDER BY c.last_message_at DESC LIMIT 100`, [userId]);
    return { items: r.rows };
  });

  app.get('/conversations/:id/messages', auth, async (req) => {
    const { id } = parse(idParam, req.params);
    const q = parse(z.object({ after: z.coerce.number().int().min(0).default(0) }), req.query);
    await memberConv(id, me(req).id);
    const r = await db.query(
      `SELECT m.id, m.sender_id AS "senderId", m.body, m.created_at AS "createdAt",
              CASE WHEN o.id IS NULL THEN NULL ELSE json_build_object('id', o.id, 'amountXaf', o.amount_xaf, 'status', o.status) END AS offer
       FROM messages m LEFT JOIN offers o ON o.id = m.offer_id
       WHERE m.conversation_id=$1 AND m.id > $2 ORDER BY m.id LIMIT 200`, [id, q.after]);
    return { items: r.rows };
  });

  app.post('/conversations/:id/messages', { ...auth, config: { rateLimit: { max: 60, timeWindow: '1 minute' } } }, async (req, reply) => {
    const { id } = parse(idParam, req.params);
    const { body } = parse(z.object({ body: z.string().trim().min(1).max(2000) }), req.body);
    const userId = me(req).id;
    const c = await memberConv(id, userId);
    const r = await db.query<{ id: number }>(
      'INSERT INTO messages (conversation_id, sender_id, body) VALUES ($1,$2,$3) RETURNING id', [id, userId, body]);
    await db.query('UPDATE conversations SET last_message_at=now() WHERE id=$1', [id]);
    await notify(db, c.buyer_id === userId ? c.seller_id : c.buyer_id, 'Nouveau message', body.slice(0, 120), `/chat/${id}`);
    return reply.code(201).send({ id: r.rows[0]!.id });
  });

  // L'acheteur propose un prix.
  app.post('/conversations/:id/offers', auth, async (req, reply) => {
    const { id } = parse(idParam, req.params);
    const { amountXaf } = parse(z.object({ amountXaf: z.number().int().positive().max(100_000_000) }), req.body);
    const userId = me(req).id;
    const c = await memberConv(id, userId);
    if (c.buyer_id !== userId) throw forbidden('only_buyer_can_offer');
    const out = await withTx(db, async (tx) => {
      const l = await tx.query<{ price_xaf: number; status: string }>('SELECT price_xaf, status FROM listings WHERE id=$1', [c.listing_id]);
      if (l.rows[0]?.status !== 'active') throw conflict('listing_unavailable');
      if (amountXaf >= l.rows[0].price_xaf) throw conflict('offer_not_below_price');
      await tx.query(`UPDATE offers SET status='declined', decided_at=now() WHERE conversation_id=$1 AND status='pending'`, [id]);
      const o = await tx.query<{ id: string }>('INSERT INTO offers (conversation_id, amount_xaf) VALUES ($1,$2) RETURNING id', [id, amountXaf]);
      await tx.query('INSERT INTO messages (conversation_id, sender_id, body, offer_id) VALUES ($1,$2,$3,$4)',
        [id, userId, `Offre : ${amountXaf} FCFA`, o.rows[0]!.id]);
      await tx.query('UPDATE conversations SET last_message_at=now() WHERE id=$1', [id]);
      await notify(tx, c.seller_id, 'Nouvelle offre', `Offre de ${amountXaf} FCFA sur ton article.`, `/chat/${id}`);
      return o.rows[0]!;
    });
    return reply.code(201).send({ id: out.id });
  });

  // Le vendeur accepte ou refuse.
  app.post('/offers/:id/decision', auth, async (req) => {
    const { id } = parse(idParam, req.params);
    const { accept } = parse(z.object({ accept: z.boolean() }), req.body);
    const userId = me(req).id;
    return withTx(db, async (tx) => {
      const r = await tx.query<{ status: string; seller_id: string; buyer_id: string; conversation_id: string; amount_xaf: number }>(
        `SELECT f.status, c.seller_id, c.buyer_id, f.conversation_id, f.amount_xaf FROM offers f
         JOIN conversations c ON c.id=f.conversation_id WHERE f.id=$1 FOR UPDATE OF f`, [id]);
      const o = r.rows[0];
      if (!o || o.seller_id !== userId) throw notFound();
      if (o.status !== 'pending') throw conflict('offer_already_decided');
      const status = accept ? 'accepted' : 'declined';
      await tx.query('UPDATE offers SET status=$2, decided_at=now() WHERE id=$1', [id, status]);
      await tx.query('INSERT INTO messages (conversation_id, sender_id, body) VALUES ($1,$2,$3)',
        [o.conversation_id, userId, accept ? `Offre de ${o.amount_xaf} FCFA acceptée` : 'Offre refusée']);
      await notify(tx, o.buyer_id, accept ? 'Offre acceptée' : 'Offre refusée',
        accept ? `Tu peux acheter pour ${o.amount_xaf} FCFA.` : 'Le vendeur a refusé ton offre.', `/chat/${o.conversation_id}`);
      return { id, status };
    });
  });
}
