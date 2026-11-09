// Restaurants (repas livrés) et boutiques locales (vêtements, électronique…).
// Un commerçant crée son commerce, un admin le valide, puis il gère son catalogue.
// Les commandes passent par le séquestre ; le commerçant fait avancer la livraison.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { withTx } from '../../db.js';
import { badRequest, conflict, forbidden, notFound, parse } from '../../lib/errors.js';
import { audit } from '../../lib/audit.js';
import { notify } from '../../lib/notify.js';
import { me, requireAuth } from '../auth/guard.js';
import { findReplay, insertOrder, viewOrder, type OrderItem } from '../orders/service.js';
import { idempotencyKey } from '../orders/routes.js';

const STORE_COLS = `id, owner_id AS "ownerId", kind, name, description, city, address,
  delivery_fee_xaf AS "deliveryFeeXaf", is_open AS "isOpen", approved, created_at AS "createdAt"`;
const PRODUCT_COLS = `id, store_id AS "storeId", name, description, category, price_xaf AS "priceXaf",
  stock, available, photo_url AS "photoUrl"`;

export async function storeRoutes(app: FastifyInstance, ctx: Ctx) {
  const { db, config } = ctx;
  const auth = { preHandler: requireAuth(ctx) };
  const admin = { preHandler: requireAuth(ctx, ['admin']) };
  const idParam = z.object({ id: z.uuid() });
  const photo = z.string().max(500).refine(
    (u) => u.startsWith('https://') || u.startsWith(`${config.PUBLIC_BASE_URL}/media/`), 'URL https ou média uploadé');

  async function ownedStore(storeId: string, userId: string) {
    const r = await db.query<{ owner_id: string; kind: string }>('SELECT owner_id, kind FROM stores WHERE id=$1', [storeId]);
    if (!r.rows[0]) throw notFound();
    if (r.rows[0].owner_id !== userId) throw forbidden();
    return r.rows[0];
  }

  app.get('/stores', async (req) => {
    const q = parse(z.object({ kind: z.enum(['restaurant', 'shop']), city: z.string().trim().max(60).optional() }), req.query);
    const args: unknown[] = [q.kind];
    const citySql = q.city ? (args.push(q.city), 'AND lower(city)=lower($2)') : '';
    const r = await db.query(`SELECT ${STORE_COLS} FROM stores WHERE kind=$1 AND approved ${citySql}
                              ORDER BY is_open DESC, name LIMIT 100`, args);
    return { items: r.rows };
  });

  app.get('/stores/mine', auth, async (req) => {
    const r = await db.query(`SELECT ${STORE_COLS} FROM stores WHERE owner_id=$1 ORDER BY created_at`, [me(req).id]);
    return { items: r.rows };
  });

  app.get('/stores/:id', async (req) => {
    const { id } = parse(idParam, req.params);
    const s = await db.query<{ approved: boolean }>(`SELECT ${STORE_COLS} FROM stores WHERE id=$1`, [id]);
    if (!s.rows[0] || !s.rows[0].approved) throw notFound();
    const p = await db.query(`SELECT ${PRODUCT_COLS} FROM products WHERE store_id=$1 AND available ORDER BY category, name`, [id]);
    return { ...s.rows[0], products: p.rows };
  });

  app.post('/stores', auth, async (req, reply) => {
    const b = parse(z.object({
      kind: z.enum(['restaurant', 'shop']),
      name: z.string().trim().min(2).max(80),
      description: z.string().trim().max(1000).default(''),
      city: z.string().trim().min(2).max(60),
      address: z.string().trim().max(200).default(''),
      deliveryFeeXaf: z.number().int().min(0).max(100_000).default(0),
    }), req.body);
    const r = await db.query(
      `INSERT INTO stores (owner_id, kind, name, description, city, address, delivery_fee_xaf)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING ${STORE_COLS}`,
      [me(req).id, b.kind, b.name, b.description, b.city, b.address, b.deliveryFeeXaf]);
    return reply.code(201).send(r.rows[0]);
  });

  app.patch('/stores/:id', auth, async (req) => {
    const { id } = parse(idParam, req.params);
    const b = parse(z.object({
      name: z.string().trim().min(2).max(80), description: z.string().trim().max(1000),
      address: z.string().trim().max(200), deliveryFeeXaf: z.number().int().min(0).max(100_000), isOpen: z.boolean(),
    }).partial().strict(), req.body);
    await ownedStore(id, me(req).id);
    const map: Record<string, string> = { deliveryFeeXaf: 'delivery_fee_xaf', isOpen: 'is_open' };
    const sets: string[] = []; const args: unknown[] = [];
    for (const [k, v] of Object.entries(b)) { args.push(v); sets.push(`${map[k] ?? k} = $${args.length}`); }
    if (!sets.length) throw badRequest('empty_update');
    args.push(id);
    const r = await db.query(`UPDATE stores SET ${sets.join(', ')} WHERE id=$${args.length} RETURNING ${STORE_COLS}`, args);
    return r.rows[0];
  });

  // ------------------------------------------------------------- Catalogue
  const productSchema = z.object({
    name: z.string().trim().min(2).max(120),
    description: z.string().trim().max(1000).default(''),
    category: z.string().trim().max(60).default(''),
    priceXaf: z.number().int().positive().max(100_000_000),
    stock: z.number().int().min(0).max(1_000_000).nullable().default(null),
    photoUrl: photo.optional(),
  });

  app.get('/stores/:id/products/all', auth, async (req) => {
    const { id } = parse(idParam, req.params);
    await ownedStore(id, me(req).id);
    const r = await db.query(`SELECT ${PRODUCT_COLS} FROM products WHERE store_id=$1 ORDER BY created_at DESC`, [id]);
    return { items: r.rows };
  });

  app.post('/stores/:id/products', auth, async (req, reply) => {
    const { id } = parse(idParam, req.params);
    const b = parse(productSchema, req.body);
    await ownedStore(id, me(req).id);
    const r = await db.query(
      `INSERT INTO products (store_id, name, description, category, price_xaf, stock, photo_url)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING ${PRODUCT_COLS}`,
      [id, b.name, b.description, b.category, b.priceXaf, b.stock, b.photoUrl ?? null]);
    return reply.code(201).send(r.rows[0]);
  });

  app.patch('/products/:id', auth, async (req) => {
    const { id } = parse(idParam, req.params);
    const b = parse(productSchema.partial().extend({ available: z.boolean().optional() }).strict(), req.body);
    const p = await db.query<{ store_id: string }>('SELECT store_id FROM products WHERE id=$1', [id]);
    if (!p.rows[0]) throw notFound();
    await ownedStore(p.rows[0].store_id, me(req).id);
    const map: Record<string, string> = { priceXaf: 'price_xaf', photoUrl: 'photo_url' };
    const sets: string[] = []; const args: unknown[] = [];
    for (const [k, v] of Object.entries(b)) { args.push(v); sets.push(`${map[k] ?? k} = $${args.length}`); }
    if (!sets.length) throw badRequest('empty_update');
    args.push(id);
    const r = await db.query(`UPDATE products SET ${sets.join(', ')} WHERE id=$${args.length} RETURNING ${PRODUCT_COLS}`, args);
    return r.rows[0];
  });

  // ------------------------------------------------------------- Commander
  app.post('/stores/:id/orders', auth, async (req, reply) => {
    const { id } = parse(idParam, req.params);
    const b = parse(z.object({
      items: z.array(z.object({ productId: z.uuid(), qty: z.number().int().min(1).max(50) })).min(1).max(30),
    }), req.body);
    const ids = b.items.map((i) => i.productId);
    if (new Set(ids).size !== ids.length) throw badRequest('duplicate_items');
    const buyerId = me(req).id;
    const key = idempotencyKey(req);
    const replay = await findReplay(db, buyerId, key);
    if (replay) return reply.code(200).send(viewOrder(replay));

    const order = await withTx(db, async (tx) => {
      const s = await tx.query<{ owner_id: string; kind: 'restaurant' | 'shop'; approved: boolean; is_open: boolean; delivery_fee_xaf: number; name: string }>(
        'SELECT owner_id, kind, approved, is_open, delivery_fee_xaf, name FROM stores WHERE id=$1', [id]);
      const store = s.rows[0];
      if (!store || !store.approved) throw notFound('store_not_found');
      if (!store.is_open) throw conflict('store_closed');
      // Verrouille les produits dans un ordre stable (évite les interblocages).
      const p = await tx.query<{ id: string; name: string; price_xaf: number; stock: number | null; available: boolean }>(
        `SELECT id, name, price_xaf, stock, available FROM products WHERE store_id=$1 AND id = ANY($2) ORDER BY id FOR UPDATE`,
        [id, ids]);
      if (p.rows.length !== ids.length) throw notFound('product_not_found');
      const byId = new Map(p.rows.map((x) => [x.id, x]));
      const items: OrderItem[] = [];
      let subtotal = 0;
      for (const it of b.items) {
        const prod = byId.get(it.productId)!;
        if (!prod.available) throw conflict('product_unavailable');
        if (prod.stock !== null && prod.stock < it.qty) throw conflict('out_of_stock');
        if (prod.stock !== null) await tx.query('UPDATE products SET stock = stock - $2 WHERE id=$1', [prod.id, it.qty]);
        items.push({ productId: prod.id, name: prod.name, qty: it.qty, unitPriceXaf: prod.price_xaf });
        subtotal += prod.price_xaf * it.qty;
      }
      if (store.delivery_fee_xaf > 0) items.push({ name: 'Livraison', qty: 1, unitPriceXaf: store.delivery_fee_xaf });
      return insertOrder(tx, ctx, {
        buyerId, sellerId: store.owner_id, kind: store.kind === 'restaurant' ? 'food' : 'shop', refId: id,
        items, itemPriceXaf: subtotal + store.delivery_fee_xaf, idempotencyKey: key,
      });
    });
    return reply.code(201).send(viewOrder(order));
  });

  // ----------------------------------------------------------------- Admin
  app.get('/admin/stores', admin, async () => {
    const r = await db.query(`SELECT ${STORE_COLS} FROM stores WHERE NOT approved ORDER BY created_at LIMIT 200`);
    return { items: r.rows };
  });

  app.post('/admin/stores/:id/approve', admin, async (req) => {
    const { id } = parse(idParam, req.params);
    const r = await db.query<{ owner_id: string; name: string }>(
      'UPDATE stores SET approved=true WHERE id=$1 RETURNING owner_id, name', [id]);
    if (!r.rows[0]) throw notFound();
    await audit(db, { actorId: me(req).id, action: 'store.approved', entity: 'store', entityId: id });
    await notify(db, r.rows[0].owner_id, 'Commerce validé', `« ${r.rows[0].name} » est maintenant visible dans l'app.`);
    return { id, approved: true };
  });
}
