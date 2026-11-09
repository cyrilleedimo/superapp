// Commandes avec séquestre : l'argent de l'acheteur est bloqué jusqu'à sa
// confirmation de réception, puis versé au portefeuille du vendeur.
//
//   pending_payment ──paiement confirmé──▶ paid ──confirmation acheteur──▶ completed
//        │                                  │
//        └──annulation──▶ cancelled         └──litige──▶ disputed ──admin──▶ refunded
import type { Ctx } from '../../context.js';
import { withTx } from '../../db.js';
import type { Tx } from '../../db.js';
import { AppError, conflict, forbidden, notFound } from '../../lib/errors.js';
import { randomToken, sha256Hex } from '../../lib/crypto.js';
import { audit } from '../../lib/audit.js';
import { post, walletAccount } from '../ledger/ledger.js';

export interface OrderRow {
  id: string; buyer_id: string; seller_id: string; listing_id: string;
  item_price_xaf: number; buyer_fee_xaf: number; total_xaf: number; status: string;
}

export function buyerFee(priceXaf: number, bps: number, fixed: number): number {
  // Arrondi au franc supérieur : la plateforme n'encaisse jamais une fraction.
  return Math.ceil((priceXaf * bps) / 10_000) + fixed;
}

const view = (o: OrderRow) => ({
  id: o.id, listingId: o.listing_id, buyerId: o.buyer_id, sellerId: o.seller_id,
  itemPriceXaf: o.item_price_xaf, buyerFeeXaf: o.buyer_fee_xaf, totalXaf: o.total_xaf, status: o.status,
});

async function lockOrder(tx: Tx, id: string): Promise<OrderRow> {
  const r = await tx.query<OrderRow>('SELECT * FROM orders WHERE id=$1 FOR UPDATE', [id]);
  if (!r.rows[0]) throw notFound();
  return r.rows[0];
}

export function makeOrderService(ctx: Ctx) {
  const { db, config, payments } = ctx;

  /** Applique l'état réel du prestataire à un paiement. Idempotent. */
  async function syncPayment(paymentId: string): Promise<string> {
    const p0 = await db.query<{ provider_reference: string | null }>(
      'SELECT provider_reference FROM payments WHERE id=$1', [paymentId]);
    const ref = p0.rows[0]?.provider_reference;
    if (!ref) return 'initiated';
    const remote = await payments.retrieve(ref);   // vérité serveur à serveur

    return withTx(db, async (tx) => {
      const pr = await tx.query<{ id: string; order_id: string; amount_xaf: number; status: string }>(
        'SELECT id, order_id, amount_xaf, status FROM payments WHERE id=$1 FOR UPDATE', [paymentId]);
      const p = pr.rows[0]!;
      if (['succeeded', 'failed', 'mismatch', 'refunded'].includes(p.status)) return p.status; // déjà traité
      const order = await lockOrder(tx, p.order_id);

      if (remote.status === 'pending') {
        await tx.query(`UPDATE payments SET status='pending', last_provider_data=$2, updated_at=now() WHERE id=$1`,
          [p.id, JSON.stringify(remote.raw)]);
        return 'pending';
      }
      if (remote.status === 'failed') {
        await tx.query(`UPDATE payments SET status='failed', last_provider_data=$2, updated_at=now() WHERE id=$1`,
          [p.id, JSON.stringify(remote.raw)]);
        return 'failed';
      }
      // Succès annoncé : on exige montant ET devise identiques à ce qui a été facturé.
      if (remote.amountXaf !== p.amount_xaf || remote.currency.toUpperCase() !== 'XAF') {
        await tx.query(`UPDATE payments SET status='mismatch', last_provider_data=$2, updated_at=now() WHERE id=$1`,
          [p.id, JSON.stringify(remote.raw)]);
        await audit(tx, { action: 'payment.mismatch', entity: 'payment', entityId: p.id,
          meta: { expected: p.amount_xaf, got: remote.amountXaf, currency: remote.currency } });
        return 'mismatch';
      }
      await tx.query(`UPDATE payments SET status='succeeded', last_provider_data=$2, updated_at=now() WHERE id=$1`,
        [p.id, JSON.stringify(remote.raw)]);
      // L'argent est chez le prestataire (créance) et bloqué en séquestre (dette envers l'acheteur).
      await post(tx, { memo: 'paiement reçu en séquestre', orderId: order.id, lines: [
        { account: 'psp:clearing', amountXaf: p.amount_xaf },
        { account: 'escrow', amountXaf: -p.amount_xaf },
      ] });
      if (order.status === 'pending_payment') {
        await tx.query(`UPDATE orders SET status='paid', paid_at=now(), updated_at=now() WHERE id=$1`, [order.id]);
      } else {
        // Payé après annulation : l'argent est tracé en séquestre, remboursement manuel requis.
        await audit(tx, { action: 'payment.after_cancel', entity: 'order', entityId: order.id });
      }
      await audit(tx, { action: 'payment.succeeded', entity: 'payment', entityId: p.id, meta: { orderId: order.id } });
      return 'succeeded';
    });
  }

  return {
    syncPayment,

    async create(buyerId: string, listingId: string, idempotencyKey: string) {
      const existing = await db.query<OrderRow>(
        'SELECT * FROM orders WHERE buyer_id=$1 AND idempotency_key=$2', [buyerId, idempotencyKey]);
      if (existing.rows[0]) return { order: view(existing.rows[0]), replayed: true };
      try {
        const order = await withTx(db, async (tx) => {
          const l = await tx.query<{ seller_id: string; price_xaf: number; status: string }>(
            'SELECT seller_id, price_xaf, status FROM listings WHERE id=$1 FOR UPDATE', [listingId]);
          const listing = l.rows[0];
          if (!listing) throw notFound('listing_not_found');
          if (listing.seller_id === buyerId) throw forbidden('cannot_buy_own_listing');
          if (listing.status !== 'active') throw conflict('listing_unavailable');
          const fee = buyerFee(listing.price_xaf, config.BUYER_FEE_BPS, config.BUYER_FEE_FIXED_XAF);
          const r = await tx.query<OrderRow>(
            `INSERT INTO orders (buyer_id, seller_id, listing_id, item_price_xaf, buyer_fee_xaf, total_xaf, idempotency_key)
             VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING *`,
            [buyerId, listing.seller_id, listingId, listing.price_xaf, fee, listing.price_xaf + fee, idempotencyKey]);
          await tx.query(`UPDATE listings SET status='reserved', updated_at=now() WHERE id=$1`, [listingId]);
          await audit(tx, { actorId: buyerId, action: 'order.create', entity: 'order', entityId: r.rows[0]!.id });
          return r.rows[0]!;
        });
        return { order: view(order), replayed: false };
      } catch (e) {
        if ((e as { code?: string }).code === '23505') throw conflict('listing_unavailable');
        throw e;
      }
    },

    async get(userId: string, orderId: string) {
      const r = await db.query<OrderRow>('SELECT * FROM orders WHERE id=$1', [orderId]);
      const o = r.rows[0];
      if (!o || (o.buyer_id !== userId && o.seller_id !== userId)) throw notFound();
      return view(o);
    },

    async listMine(userId: string) {
      const r = await db.query<OrderRow>(
        `SELECT * FROM orders WHERE buyer_id=$1 OR seller_id=$1 ORDER BY created_at DESC LIMIT 100`, [userId]);
      return r.rows.map(view);
    },

    /** Démarre le paiement hébergé chez le prestataire et renvoie l'URL de paiement. */
    async startPayment(buyerId: string, orderId: string) {
      const o = await db.query<OrderRow & { phone: string; display_name: string; email: string | null }>(
        `SELECT o.*, u.phone, u.display_name, u.email FROM orders o JOIN users u ON u.id = o.buyer_id WHERE o.id=$1`,
        [orderId]);
      const order = o.rows[0];
      if (!order || order.buyer_id !== buyerId) throw notFound();
      if (order.status !== 'pending_payment') throw conflict('order_not_payable');

      // Réutilise une session encore ouverte plutôt que d'en créer une nouvelle.
      const open = await db.query<{ our_reference: string; checkout_url: string }>(
        `SELECT our_reference, checkout_url FROM payments
         WHERE order_id=$1 AND status='pending' AND checkout_url IS NOT NULL
           AND created_at > now() - interval '30 minutes' ORDER BY created_at DESC LIMIT 1`, [orderId]);
      if (open.rows[0]) return { reference: open.rows[0].our_reference, checkoutUrl: open.rows[0].checkout_url };

      const ourReference = `ord_${orderId.slice(0, 8)}_${randomToken(9)}`;
      const ins = await db.query<{ id: string }>(
        `INSERT INTO payments (order_id, provider, our_reference, amount_xaf) VALUES ($1,$2,$3,$4) RETURNING id`,
        [orderId, payments.name, ourReference, order.total_xaf]);
      const paymentId = ins.rows[0]!.id;
      try {
        const init = await payments.initialize({
          ourReference, amountXaf: order.total_xaf, description: `Commande ${orderId.slice(0, 8)}`,
          customer: { name: order.display_name, phone: order.phone, email: order.email },
          callbackUrl: config.PAYMENT_CALLBACK_URL,
        });
        await db.query(
          `UPDATE payments SET provider_reference=$2, checkout_url=$3, status='pending', updated_at=now() WHERE id=$1`,
          [paymentId, init.providerReference, init.checkoutUrl]);
        await audit(db, { actorId: buyerId, action: 'payment.start', entity: 'payment', entityId: paymentId });
        return { reference: ourReference, checkoutUrl: init.checkoutUrl };
      } catch (e) {
        await db.query(`UPDATE payments SET status='failed', updated_at=now() WHERE id=$1`, [paymentId]);
        throw new AppError(502, 'payment_provider_unavailable', (e as Error).message);
      }
    },

    /** Le client revient du paiement : on resynchronise depuis le prestataire. */
    async refreshPayment(buyerId: string, ourReference: string) {
      const r = await db.query<{ id: string; buyer_id: string }>(
        `SELECT p.id, o.buyer_id FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.our_reference=$1`,
        [ourReference]);
      const row = r.rows[0];
      if (!row || row.buyer_id !== buyerId) throw notFound();
      return { status: await syncPayment(row.id) };
    },

    /** Webhook : signature vérifiée, anti-rejeu, puis resynchronisation serveur à serveur. */
    async handleWebhook(rawBody: string, headers: Record<string, string | string[] | undefined>, body: unknown) {
      if (!payments.verifyWebhook(rawBody, headers)) throw new AppError(401, 'invalid_signature');
      const ins = await db.query(
        `INSERT INTO webhook_events (provider, body_sha256) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
        [payments.name, sha256Hex(rawBody)]);
      if (!ins.rowCount) return { outcome: 'duplicate' };
      const refs = payments.referencesFromWebhook(body);
      if (!refs.length) return { outcome: 'ignored' };
      const r = await db.query<{ id: string }>(
        `SELECT id FROM payments WHERE provider=$1 AND (provider_reference = ANY($2) OR our_reference = ANY($2)) LIMIT 1`,
        [payments.name, refs]);
      if (!r.rows[0]) return { outcome: 'unknown_payment' };
      return { outcome: await syncPayment(r.rows[0].id) };
    },

    /** L'acheteur confirme la réception : le séquestre est libéré. */
    async confirmReceipt(buyerId: string, orderId: string) {
      return withTx(db, async (tx) => {
        const o = await lockOrder(tx, orderId);
        if (o.buyer_id !== buyerId) throw notFound();
        if (o.status !== 'paid') throw conflict('order_not_confirmable');
        await post(tx, { memo: 'libération du séquestre', orderId, lines: [
          { account: 'escrow', amountXaf: o.total_xaf },
          { account: walletAccount(o.seller_id), amountXaf: -o.item_price_xaf },
          ...(o.buyer_fee_xaf > 0 ? [{ account: 'platform:revenue', amountXaf: -o.buyer_fee_xaf }] : []),
        ] });
        await tx.query(`UPDATE orders SET status='completed', completed_at=now(), updated_at=now() WHERE id=$1`, [orderId]);
        await tx.query(`UPDATE listings SET status='sold', updated_at=now() WHERE id=$1`, [o.listing_id]);
        await audit(tx, { actorId: buyerId, action: 'order.completed', entity: 'order', entityId: orderId });
        return view({ ...o, status: 'completed' });
      });
    },

    async cancel(userId: string, orderId: string) {
      return withTx(db, async (tx) => {
        const o = await lockOrder(tx, orderId);
        if (o.buyer_id !== userId && o.seller_id !== userId) throw notFound();
        if (o.status !== 'pending_payment') throw conflict('order_not_cancellable');
        await tx.query(`UPDATE orders SET status='cancelled', updated_at=now() WHERE id=$1`, [orderId]);
        await tx.query(`UPDATE listings SET status='active', updated_at=now() WHERE id=$1 AND status='reserved'`, [o.listing_id]);
        await audit(tx, { actorId: userId, action: 'order.cancelled', entity: 'order', entityId: orderId });
        return view({ ...o, status: 'cancelled' });
      });
    },

    async dispute(buyerId: string, orderId: string, reason: string) {
      return withTx(db, async (tx) => {
        const o = await lockOrder(tx, orderId);
        if (o.buyer_id !== buyerId) throw notFound();
        if (o.status !== 'paid') throw conflict('order_not_disputable');
        await tx.query(`UPDATE orders SET status='disputed', updated_at=now() WHERE id=$1`, [orderId]);
        await audit(tx, { actorId: buyerId, action: 'order.disputed', entity: 'order', entityId: orderId, meta: { reason } });
        return view({ ...o, status: 'disputed' });
      });
    },

    /** Admin : rembourse l'acheteur (écriture comptable). L'appel de remboursement
     *  chez le prestataire est exécuté hors ligne en Phase 1 (voir docs/ROADMAP). */
    async refund(adminId: string, orderId: string) {
      return withTx(db, async (tx) => {
        const o = await lockOrder(tx, orderId);
        if (!['paid', 'disputed'].includes(o.status)) throw conflict('order_not_refundable');
        await post(tx, { memo: 'remboursement acheteur', orderId, lines: [
          { account: 'escrow', amountXaf: o.total_xaf },
          { account: 'psp:clearing', amountXaf: -o.total_xaf },
        ] });
        await tx.query(`UPDATE orders SET status='refunded', updated_at=now() WHERE id=$1`, [orderId]);
        await tx.query(`UPDATE listings SET status='active', updated_at=now() WHERE id=$1`, [o.listing_id]);
        await tx.query(`UPDATE payments SET status='refunded', updated_at=now() WHERE order_id=$1 AND status='succeeded'`, [orderId]);
        await audit(tx, { actorId: adminId, action: 'order.refunded', entity: 'order', entityId: orderId });
        return view({ ...o, status: 'refunded' });
      });
    },
  };
}
