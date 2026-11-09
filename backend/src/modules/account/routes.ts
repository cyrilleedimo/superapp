// Notifications in-app et retraits du porte-monnaie vers Mobile Money.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { withTx } from '../../db.js';
import { AppError, conflict, notFound, parse } from '../../lib/errors.js';
import { audit } from '../../lib/audit.js';
import { notify } from '../../lib/notify.js';
import { me, requireAuth } from '../auth/guard.js';
import { balance, post, walletAccount } from '../ledger/ledger.js';

export async function accountRoutes(app: FastifyInstance, ctx: Ctx) {
  const { db, config } = ctx;
  const auth = { preHandler: requireAuth(ctx) };
  const admin = { preHandler: requireAuth(ctx, ['admin']) };
  const idParam = z.object({ id: z.uuid() });

  // ------------------------------------------------------- Notifications
  app.get('/notifications', auth, async (req) => {
    const r = await db.query(
      `SELECT id, title, body, link, read_at IS NOT NULL AS read, created_at AS "createdAt"
       FROM notifications WHERE user_id=$1 ORDER BY id DESC LIMIT 100`, [me(req).id]);
    const unread = await db.query<{ n: number }>(
      'SELECT count(*)::int AS n FROM notifications WHERE user_id=$1 AND read_at IS NULL', [me(req).id]);
    return { items: r.rows, unread: unread.rows[0]?.n ?? 0 };
  });

  app.post('/notifications/read-all', auth, async (req, reply) => {
    await db.query('UPDATE notifications SET read_at=now() WHERE user_id=$1 AND read_at IS NULL', [me(req).id]);
    return reply.code(204).send();
  });

  // ------------------------------------------------------------ Retraits
  app.get('/payouts', auth, async (req) => {
    const r = await db.query(
      `SELECT id, amount_xaf AS "amountXaf", msisdn, channel, status, created_at AS "createdAt"
       FROM payouts WHERE user_id=$1 ORDER BY created_at DESC LIMIT 50`, [me(req).id]);
    return { items: r.rows };
  });

  app.post('/payouts', { ...auth, config: { rateLimit: { max: 5, timeWindow: '1 minute' } } }, async (req, reply) => {
    const b = parse(z.object({
      amountXaf: z.number().int().positive(),
      msisdn: z.string().regex(/^\+[1-9][0-9]{7,14}$/),
      channel: z.enum(['orange_money', 'mtn_momo']),
    }), req.body);
    if (b.amountXaf < config.PAYOUT_MIN_XAF) throw new AppError(400, 'payout_below_minimum');
    const userId = me(req).id;
    const out = await withTx(db, async (tx) => {
      // Verrou consultatif par utilisateur : deux demandes simultanées ne peuvent pas
      // dépenser deux fois le même solde.
      await tx.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`payout:${userId}`]);
      const available = -(await balance(tx, walletAccount(userId)));
      if (b.amountXaf > available) throw conflict('insufficient_balance');
      const p = await tx.query<{ id: string }>(
        `INSERT INTO payouts (user_id, amount_xaf, msisdn, channel) VALUES ($1,$2,$3,$4) RETURNING id`,
        [userId, b.amountXaf, b.msisdn, b.channel]);
      await post(tx, { memo: 'demande de retrait', lines: [
        { account: walletAccount(userId), amountXaf: b.amountXaf },
        { account: 'payouts:pending', amountXaf: -b.amountXaf },
      ] });
      await audit(tx, { actorId: userId, action: 'payout.request', entity: 'payout', entityId: p.rows[0]!.id, ip: req.ip });
      return p.rows[0]!;
    });
    return reply.code(201).send({ id: out.id, status: 'requested' });
  });

  // Admin : le virement est fait depuis le tableau de bord du prestataire, puis marqué ici.
  app.get('/admin/payouts', admin, async () => {
    const r = await db.query(
      `SELECT p.id, p.amount_xaf AS "amountXaf", p.msisdn, p.channel, p.created_at AS "createdAt", u.display_name AS "userName"
       FROM payouts p JOIN users u ON u.id=p.user_id WHERE p.status='requested' ORDER BY p.created_at`);
    return { items: r.rows };
  });

  app.post('/admin/payouts/:id/decision', admin, async (req) => {
    const { id } = parse(idParam, req.params);
    const { paid } = parse(z.object({ paid: z.boolean() }), req.body);
    const adminId = me(req).id;
    return withTx(db, async (tx) => {
      const r = await tx.query<{ user_id: string; amount_xaf: number; status: string }>(
        'SELECT user_id, amount_xaf, status FROM payouts WHERE id=$1 FOR UPDATE', [id]);
      const p = r.rows[0];
      if (!p) throw notFound();
      if (p.status !== 'requested') throw conflict('payout_already_processed');
      await post(tx, paid
        ? { memo: 'retrait versé', lines: [
            { account: 'payouts:pending', amountXaf: p.amount_xaf },
            { account: 'psp:clearing', amountXaf: -p.amount_xaf },
          ] }
        : { memo: 'retrait refusé, solde restitué', lines: [
            { account: 'payouts:pending', amountXaf: p.amount_xaf },
            { account: walletAccount(p.user_id), amountXaf: -p.amount_xaf },
          ] });
      await tx.query(`UPDATE payouts SET status=$2, processed_by=$3, processed_at=now() WHERE id=$1`,
        [id, paid ? 'paid' : 'rejected', adminId]);
      await audit(tx, { actorId: adminId, action: paid ? 'payout.paid' : 'payout.rejected', entity: 'payout', entityId: id });
      await notify(tx, p.user_id, paid ? 'Retrait envoyé' : 'Retrait refusé',
        paid ? `${p.amount_xaf} FCFA ont été envoyés sur ton compte Mobile Money.`
             : 'Ton retrait a été refusé, le montant est revenu dans ton porte-monnaie.');
      return { id, status: paid ? 'paid' : 'rejected' };
    });
  });
}
