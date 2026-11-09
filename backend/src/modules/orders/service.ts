// Commandes avec séquestre, communes à tous les services (seconde main,
// covoiturage, repas, boutiques). L'argent de l'acheteur est bloqué jusqu'à sa
// confirmation, puis versé au portefeuille du vendeur / chauffeur / commerçant.
//
//   pending_payment ──paiement confirmé──▶ paid ──confirmation acheteur──▶ completed
//        │ (annulation ou expiration)       │
//        └──▶ cancelled                     └──litige──▶ disputed ──admin──▶ refunded | completed
import type { Ctx } from '../../context.js';
import { withTx } from '../../db.js';
import type { Db, Tx } from '../../db.js';
import { AppError, conflict, forbidden, notFound } from '../../lib/errors.js';
import { randomToken, sha256Hex } from '../../lib/crypto.js';
import { audit } from '../../lib/audit.js';
import { notify } from '../../lib/notify.js';
import { post, walletAccount } from '../ledger/ledger.js';

export type OrderKind = 'listing' | 'carpool' | 'food' | 'shop';

export interface OrderItem { productId?: string; name: string; qty: number; unitPriceXaf: number }

export interface OrderRow {
  id: string; buyer_id: string; seller_id: string; listing_id: string | null;
  kind: OrderKind; ref_id: string | null; items: OrderItem[]; fulfillment: string | null;
  item_price_xaf: number; buyer_fee_xaf: number; total_xaf: number; status: string;
  offer_id: string | null; created_at: Date; paid_at: Date | null;
}

export function buyerFee(priceXaf: number, bps: number, fixed: number): number {
  // Arrondi au franc supérieur : la plateforme n'encaisse jamais une fraction.
  return Math.ceil((priceXaf * bps) / 10_000) + fixed;
}

export const viewOrder = (o: OrderRow) => ({
  id: o.id, kind: o.kind, listingId: o.listing_id, refId: o.ref_id, items: o.items,
  buyerId: o.buyer_id, sellerId: o.seller_id, fulfillment: o.fulfillment,
  itemPriceXaf: o.item_price_xaf, buyerFeeXaf: o.buyer_fee_xaf, totalXaf: o.total_xaf,
  status: o.status, createdAt: o.created_at,
});

export async function lockOrder(tx: Tx, id: string): Promise<OrderRow> {
  const r = await tx.query<OrderRow>('SELECT * FROM orders WHERE id=$1 FOR UPDATE', [id]);
  if (!r.rows[0]) throw notFound();
  return r.rows[0];
}

/** Insère une commande (à appeler dans la transaction qui a réservé le stock / les places). */
export async function insertOrder(tx: Tx, ctx: Ctx, o: {
  buyerId: string; sellerId: string; kind: OrderKind; listingId?: string; refId?: string;
  items?: OrderItem[]; itemPriceXaf: number; idempotencyKey: string; offerId?: string;
}): Promise<OrderRow> {
  if (o.buyerId === o.sellerId) throw forbidden('cannot_buy_from_yourself');
  const fee = buyerFee(o.itemPriceXaf, ctx.config.BUYER_FEE_BPS, ctx.config.BUYER_FEE_FIXED_XAF);
  const r = await tx.query<OrderRow>(
    `INSERT INTO orders (buyer_id, seller_id, kind, listing_id, ref_id, items, item_price_xaf, buyer_fee_xaf,
                         total_xaf, idempotency_key, offer_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING *`,
    [o.buyerId, o.sellerId, o.kind, o.listingId ?? null, o.refId ?? null, JSON.stringify(o.items ?? []),
     o.itemPriceXaf, fee, o.itemPriceXaf + fee, o.idempotencyKey, o.offerId ?? null]);
  await audit(tx, { actorId: o.buyerId, action: 'order.create', entity: 'order', entityId: r.rows[0]!.id, meta: { kind: o.kind } });
  return r.rows[0]!;
}

/** Retourne la commande déjà créée avec cette clé d'idempotence, s'il y en a une. */
export async function findReplay(db: Db, buyerId: string, key: string): Promise<OrderRow | undefined> {
  return (await db.query<OrderRow>('SELECT * FROM orders WHERE buyer_id=$1 AND idempotency_key=$2', [buyerId, key])).rows[0];
}

/** Rend disponible ce que la commande avait réservé (article, places, stock). */
async function releaseReservation(tx: Tx, o: OrderRow): Promise<void> {
  if (o.kind === 'listing' && o.listing_id) {
    await tx.query(`UPDATE listings SET status='active', updated_at=now() WHERE id=$1 AND status='reserved'`, [o.listing_id]);
    if (o.offer_id) await tx.query(`UPDATE offers SET status='accepted' WHERE id=$1 AND status='used'`, [o.offer_id]);
  } else if (o.kind === 'carpool' && o.ref_id) {
    const seats = o.items.reduce((s, i) => s + i.qty, 0);
    await tx.query('UPDATE trips SET seats_left = LEAST(seats_total, seats_left + $2) WHERE id=$1', [o.ref_id, seats]);
  } else if (o.kind === 'shop') {
    for (const it of o.items) {
      if (it.productId) await tx.query('UPDATE products SET stock = stock + $2 WHERE id=$1 AND stock IS NOT NULL', [it.productId, it.qty]);
    }
  }
}

const KIND_LABEL: Record<OrderKind, string> = { listing: 'article', carpool: 'réservation de trajet', food: 'commande repas', shop: 'commande boutique' };

export function makeOrderService(ctx: Ctx) {
  const { db, config, payments } = ctx;

  /** Libère le séquestre vers le vendeur. Utilisé par l'acheteur, l'admin et la libération auto. */
  async function release(tx: Tx, o: OrderRow, actorId: string | null, reason: string) {
    await post(tx, { memo: `libération du séquestre (${reason})`, orderId: o.id, lines: [
      { account: 'escrow', amountXaf: o.total_xaf },
      { account: walletAccount(o.seller_id), amountXaf: -o.item_price_xaf },
      ...(o.buyer_fee_xaf > 0 ? [{ account: 'platform:revenue', amountXaf: -o.buyer_fee_xaf }] : []),
    ] });
    await tx.query(`UPDATE orders SET status='completed', completed_at=now(), updated_at=now() WHERE id=$1`, [o.id]);
    if (o.kind === 'listing' && o.listing_id) {
      await tx.query(`UPDATE listings SET status='sold', updated_at=now() WHERE id=$1`, [o.listing_id]);
    }
    await audit(tx, { actorId, action: 'order.completed', entity: 'order', entityId: o.id, meta: { reason } });
    await notify(tx, o.seller_id, 'Paiement libéré',
      `${o.item_price_xaf} FCFA ont été ajoutés à ton porte-monnaie.`, `/orders/${o.id}`);
  }

  async function cancelLocked(tx: Tx, o: OrderRow, actorId: string | null, reason: string) {
    await tx.query(`UPDATE orders SET status='cancelled', updated_at=now() WHERE id=$1`, [o.id]);
    await releaseReservation(tx, o);
    await audit(tx, { actorId, action: 'order.cancelled', entity: 'order', entityId: o.id, meta: { reason } });
  }

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
      const raw = JSON.stringify(remote.raw);

      if (remote.status === 'pending') {
        await tx.query(`UPDATE payments SET status='pending', last_provider_data=$2, updated_at=now() WHERE id=$1`, [p.id, raw]);
        return 'pending';
      }
      if (remote.status === 'failed') {
        await tx.query(`UPDATE payments SET status='failed', last_provider_data=$2, updated_at=now() WHERE id=$1`, [p.id, raw]);
        return 'failed';
      }
      // Succès annoncé : on exige montant ET devise identiques à ce qui a été facturé.
      if (remote.amountXaf !== p.amount_xaf || remote.currency.toUpperCase() !== 'XAF') {
        await tx.query(`UPDATE payments SET status='mismatch', last_provider_data=$2, updated_at=now() WHERE id=$1`, [p.id, raw]);
        await audit(tx, { action: 'payment.mismatch', entity: 'payment', entityId: p.id,
          meta: { expected: p.amount_xaf, got: remote.amountXaf, currency: remote.currency } });
        return 'mismatch';
      }
      await tx.query(`UPDATE payments SET status='succeeded', last_provider_data=$2, updated_at=now() WHERE id=$1`, [p.id, raw]);
      await post(tx, { memo: 'paiement reçu en séquestre', orderId: order.id, lines: [
        { account: 'psp:clearing', amountXaf: p.amount_xaf },
        { account: 'escrow', amountXaf: -p.amount_xaf },
      ] });
      if (order.status === 'pending_payment') {
        await tx.query(`UPDATE orders SET status='paid', paid_at=now(), updated_at=now() WHERE id=$1`, [order.id]);
        await notify(tx, order.seller_id, 'Nouvelle commande payée',
          `Une ${KIND_LABEL[order.kind]} vient d'être payée. L'argent est en séquestre.`, `/orders/${order.id}`);
      } else {
        // Payé après annulation : l'argent est tracé en séquestre, remboursement par un admin requis.
        await audit(tx, { action: 'payment.after_cancel', entity: 'order', entityId: order.id });
      }
      await audit(tx, { action: 'payment.succeeded', entity: 'payment', entityId: p.id, meta: { orderId: order.id } });
      return 'succeeded';
    });
  }

  return {
    syncPayment,

    /** Achat d'une annonce de seconde main (au prix affiché ou au prix d'une offre acceptée). */
    async createListingOrder(buyerId: string, listingId: string, idempotencyKey: string, offerId?: string) {
      const existing = await findReplay(db, buyerId, idempotencyKey);
      if (existing) return { order: viewOrder(existing), replayed: true };
      try {
        const order = await withTx(db, async (tx) => {
          const l = await tx.query<{ seller_id: string; price_xaf: number; status: string; title: string }>(
            'SELECT seller_id, price_xaf, status, title FROM listings WHERE id=$1 FOR UPDATE', [listingId]);
          const listing = l.rows[0];
          if (!listing) throw notFound('listing_not_found');
          if (listing.seller_id === buyerId) throw forbidden('cannot_buy_own_listing');
          if (listing.status !== 'active') throw conflict('listing_unavailable');
          let price = listing.price_xaf;
          if (offerId) {
            const o = await tx.query<{ amount_xaf: number; status: string; buyer_id: string; listing_id: string }>(
              `SELECT f.amount_xaf, f.status, c.buyer_id, c.listing_id FROM offers f
               JOIN conversations c ON c.id = f.conversation_id WHERE f.id=$1 FOR UPDATE OF f`, [offerId]);
            const offer = o.rows[0];
            if (!offer || offer.buyer_id !== buyerId || offer.listing_id !== listingId) throw notFound('offer_not_found');
            if (offer.status !== 'accepted') throw conflict('offer_not_accepted');
            price = offer.amount_xaf;
            await tx.query(`UPDATE offers SET status='used' WHERE id=$1`, [offerId]);
          }
          const row = await insertOrder(tx, ctx, {
            buyerId, sellerId: listing.seller_id, kind: 'listing', listingId,
            items: [{ name: listing.title, qty: 1, unitPriceXaf: price }],
            itemPriceXaf: price, idempotencyKey, offerId,
          });
          await tx.query(`UPDATE listings SET status='reserved', updated_at=now() WHERE id=$1`, [listingId]);
          return row;
        });
        return { order: viewOrder(order), replayed: false };
      } catch (e) {
        if ((e as { code?: string }).code === '23505') throw conflict('listing_unavailable');
        throw e;
      }
    },

    async get(userId: string, orderId: string) {
      const r = await db.query<OrderRow>('SELECT * FROM orders WHERE id=$1', [orderId]);
      const o = r.rows[0];
      if (!o || (o.buyer_id !== userId && o.seller_id !== userId)) throw notFound();
      return viewOrder(o);
    },

    async listMine(userId: string, role: 'buyer' | 'seller' | 'all' = 'all') {
      const where = role === 'buyer' ? 'buyer_id=$1' : role === 'seller' ? 'seller_id=$1' : '(buyer_id=$1 OR seller_id=$1)';
      const r = await db.query<OrderRow>(`SELECT * FROM orders WHERE ${where} ORDER BY created_at DESC LIMIT 100`, [userId]);
      return r.rows.map(viewOrder);
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
        await release(tx, o, buyerId, 'confirmation acheteur');
        return viewOrder({ ...o, status: 'completed' });
      });
    },

    /** Le vendeur / commerçant fait avancer la préparation ou la livraison. */
    async setFulfillment(sellerId: string, orderId: string, step: 'accepted' | 'preparing' | 'ready' | 'delivering' | 'delivered') {
      return withTx(db, async (tx) => {
        const o = await lockOrder(tx, orderId);
        if (o.seller_id !== sellerId) throw notFound();
        if (o.status !== 'paid') throw conflict('order_not_paid');
        const flow = ['accepted', 'preparing', 'ready', 'delivering', 'delivered'];
        if (o.fulfillment && flow.indexOf(step) <= flow.indexOf(o.fulfillment)) throw conflict('invalid_transition');
        await tx.query('UPDATE orders SET fulfillment=$2, updated_at=now() WHERE id=$1', [orderId, step]);
        const labels: Record<string, string> = {
          accepted: 'Ta commande est acceptée', preparing: 'Ta commande est en préparation', ready: 'Ta commande est prête',
          delivering: 'Ta commande est en route', delivered: 'Commande livrée : confirme la réception',
        };
        await notify(tx, o.buyer_id, labels[step]!, 'Suis ta commande dans l\'app.', `/orders/${orderId}`);
        return viewOrder({ ...o, fulfillment: step });
      });
    },

    async cancel(userId: string, orderId: string) {
      return withTx(db, async (tx) => {
        const o = await lockOrder(tx, orderId);
        if (o.buyer_id !== userId && o.seller_id !== userId) throw notFound();
        if (o.status !== 'pending_payment') throw conflict('order_not_cancellable');
        await cancelLocked(tx, o, userId, 'utilisateur');
        return viewOrder({ ...o, status: 'cancelled' });
      });
    },

    async dispute(buyerId: string, orderId: string, reason: string) {
      return withTx(db, async (tx) => {
        const o = await lockOrder(tx, orderId);
        if (o.buyer_id !== buyerId) throw notFound();
        if (o.status !== 'paid') throw conflict('order_not_disputable');
        await tx.query(`UPDATE orders SET status='disputed', updated_at=now() WHERE id=$1`, [orderId]);
        await audit(tx, { actorId: buyerId, action: 'order.disputed', entity: 'order', entityId: orderId, meta: { reason } });
        await notify(tx, o.seller_id, 'Litige ouvert', 'L\'acheteur a signalé un problème. Notre équipe va examiner la commande.', `/orders/${orderId}`);
        return viewOrder({ ...o, status: 'disputed' });
      });
    },

    /** Admin : tranche un litige en faveur du vendeur. */
    async adminRelease(adminId: string, orderId: string) {
      return withTx(db, async (tx) => {
        const o = await lockOrder(tx, orderId);
        if (!['paid', 'disputed'].includes(o.status)) throw conflict('order_not_releasable');
        await release(tx, o, adminId, 'décision admin');
        return viewOrder({ ...o, status: 'completed' });
      });
    },

    /** Admin : rembourse l'acheteur (écriture comptable). Le virement retour chez le
     *  prestataire est exécuté depuis son tableau de bord (voir docs/SECURITY.md). */
    async refund(adminId: string, orderId: string) {
      return withTx(db, async (tx) => {
        const o = await lockOrder(tx, orderId);
        if (!['paid', 'disputed'].includes(o.status)) throw conflict('order_not_refundable');
        await post(tx, { memo: 'remboursement acheteur', orderId, lines: [
          { account: 'escrow', amountXaf: o.total_xaf },
          { account: 'psp:clearing', amountXaf: -o.total_xaf },
        ] });
        await tx.query(`UPDATE orders SET status='refunded', updated_at=now() WHERE id=$1`, [orderId]);
        await releaseReservation(tx, o);
        await tx.query(`UPDATE payments SET status='refunded', updated_at=now() WHERE order_id=$1 AND status='succeeded'`, [orderId]);
        await audit(tx, { actorId: adminId, action: 'order.refunded', entity: 'order', entityId: orderId });
        await notify(tx, o.buyer_id, 'Remboursement validé', `${o.total_xaf} FCFA vont t'être reversés.`, `/orders/${orderId}`);
        return viewOrder({ ...o, status: 'refunded' });
      });
    },

    // ---------------------------------------------------- tâches planifiées
    /** Annule les commandes non payées après PENDING_ORDER_TTL_MIN minutes. */
    async expirePending(): Promise<number> {
      const ids = (await db.query<{ id: string }>(
        `SELECT id FROM orders WHERE status='pending_payment'
         AND created_at < now() - make_interval(mins => $1) LIMIT 200`, [config.PENDING_ORDER_TTL_MIN])).rows;
      let n = 0;
      for (const { id } of ids) {
        await withTx(db, async (tx) => {
          const o = await lockOrder(tx, id);
          if (o.status !== 'pending_payment') return;
          // Un paiement peut être en cours : on ne coupe pas une session de moins de 30 min.
          const live = await tx.query(`SELECT 1 FROM payments WHERE order_id=$1 AND status='pending'
                                       AND created_at > now() - interval '30 minutes'`, [id]);
          if (live.rowCount) return;
          await cancelLocked(tx, o, null, 'expiration');
          n++;
        });
      }
      return n;
    },

    /** Libère automatiquement le séquestre après AUTO_RELEASE_DAYS jours sans litige. */
    async autoRelease(): Promise<number> {
      if (!config.AUTO_RELEASE_DAYS) return 0;
      const ids = (await db.query<{ id: string }>(
        `SELECT id FROM orders WHERE status='paid' AND paid_at < now() - make_interval(days => $1) LIMIT 200`,
        [config.AUTO_RELEASE_DAYS])).rows;
      for (const { id } of ids) {
        await withTx(db, async (tx) => {
          const o = await lockOrder(tx, id);
          if (o.status === 'paid') await release(tx, o, null, 'libération automatique');
        });
      }
      return ids.length;
    },
  };
}
export type OrderService = ReturnType<typeof makeOrderService>;
