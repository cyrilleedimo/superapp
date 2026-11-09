// Seconde main : annonces (création, recherche plein texte, pagination par curseur).
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { forbidden, notFound, parse, badRequest } from '../../lib/errors.js';
import { audit } from '../../lib/audit.js';
import { me, requireAuth } from '../auth/guard.js';

export const CATEGORIES = ['women', 'men', 'kids', 'electronics', 'home', 'beauty', 'sports', 'other'] as const;
const CONDITIONS = ['new', 'very_good', 'good', 'fair'] as const;

// Photos : uniquement des URL https (l'upload signé arrive en Phase 2).
const photoUrl = z.url({ protocol: /^https$/ }).max(500);

const createSchema = z.object({
  title: z.string().trim().min(3).max(120),
  description: z.string().trim().max(4000).default(''),
  category: z.enum(CATEGORIES),
  condition: z.enum(CONDITIONS),
  priceXaf: z.number().int().positive().max(100_000_000),
  city: z.string().trim().min(2).max(60),
  photos: z.array(photoUrl).max(10).default([]),
});

const COLS = `id, seller_id AS "sellerId", title, description, category, condition,
  price_xaf AS "priceXaf", city, photos, status, created_at AS "createdAt"`;

// Curseur opaque = base64url("<created_at ISO>|<id>")
const encodeCursor = (createdAt: Date, id: string) =>
  Buffer.from(`${createdAt.toISOString()}|${id}`).toString('base64url');
function decodeCursor(c: string): [string, string] {
  const [ts, id] = Buffer.from(c, 'base64url').toString().split('|');
  if (!ts || !id || Number.isNaN(Date.parse(ts)) || !/^[0-9a-f-]{36}$/.test(id)) throw badRequest('invalid_cursor');
  return [ts, id];
}

export async function marketplaceRoutes(app: FastifyInstance, ctx: Ctx) {
  const { db } = ctx;

  app.get('/listings', async (req) => {
    const q = parse(z.object({
      q: z.string().trim().max(100).optional(),
      category: z.enum(CATEGORIES).optional(),
      city: z.string().trim().max(60).optional(),
      minPrice: z.coerce.number().int().min(0).optional(),
      maxPrice: z.coerce.number().int().min(0).optional(),
      cursor: z.string().max(200).optional(),
      limit: z.coerce.number().int().min(1).max(50).default(20),
    }), req.query);

    const where: string[] = [`status = 'active'`];
    const args: unknown[] = [];
    const add = (sql: string, v: unknown) => { args.push(v); where.push(sql.replace('?', `$${args.length}`)); };
    if (q.q) add(`search_doc @@ plainto_tsquery('french', ?)`, q.q);
    if (q.category) add('category = ?', q.category);
    if (q.city) add('lower(city) = lower(?)', q.city);
    if (q.minPrice !== undefined) add('price_xaf >= ?', q.minPrice);
    if (q.maxPrice !== undefined) add('price_xaf <= ?', q.maxPrice);
    if (q.cursor) {
      const [ts, id] = decodeCursor(q.cursor);
      args.push(ts, id);
      where.push(`(created_at, id) < ($${args.length - 1}::timestamptz, $${args.length}::uuid)`);
    }
    args.push(q.limit + 1);
    const r = await db.query(
      `SELECT ${COLS} FROM listings WHERE ${where.join(' AND ')}
       ORDER BY created_at DESC, id DESC LIMIT $${args.length}`, args);
    const items = r.rows.slice(0, q.limit);
    const last = items[items.length - 1];
    return { items, nextCursor: r.rows.length > q.limit && last ? encodeCursor(last.createdAt, last.id) : null };
  });

  app.get('/listings/:id', async (req) => {
    const { id } = parse(z.object({ id: z.uuid() }), req.params);
    const r = await db.query(
      `SELECT l.id, l.title, l.description, l.category, l.condition, l.price_xaf AS "priceXaf",
              l.city, l.photos, l.status, l.created_at AS "createdAt",
              json_build_object('id', u.id, 'displayName', u.display_name) AS seller
       FROM listings l JOIN users u ON u.id = l.seller_id
       WHERE l.id=$1 AND l.status <> 'removed'`, [id]);
    if (!r.rows[0]) throw notFound();
    return r.rows[0];
  });

  app.post('/listings', { preHandler: requireAuth(ctx) }, async (req, reply) => {
    const b = parse(createSchema, req.body);
    const user = me(req);
    const r = await db.query(
      `INSERT INTO listings (seller_id, title, description, category, condition, price_xaf, city, photos)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8) RETURNING ${COLS}`,
      [user.id, b.title, b.description, b.category, b.condition, b.priceXaf, b.city, JSON.stringify(b.photos)]);
    await audit(db, { actorId: user.id, action: 'listing.create', entity: 'listing', entityId: r.rows[0].id, ip: req.ip });
    return reply.code(201).send(r.rows[0]);
  });

  app.patch('/listings/:id', { preHandler: requireAuth(ctx) }, async (req) => {
    const { id } = parse(z.object({ id: z.uuid() }), req.params);
    const b = parse(createSchema.partial().strict(), req.body);
    const owner = await db.query<{ seller_id: string; status: string }>(
      'SELECT seller_id, status FROM listings WHERE id=$1', [id]);
    const row = owner.rows[0];
    if (!row) throw notFound();
    if (row.seller_id !== me(req).id) throw forbidden();
    // Une annonce réservée ou vendue ne change plus de prix (protège l'acheteur).
    if (row.status !== 'active') throw badRequest('listing_locked');
    const map: Record<string, string> = { priceXaf: 'price_xaf' };
    const sets: string[] = []; const args: unknown[] = [];
    for (const [k, v] of Object.entries(b)) {
      args.push(k === 'photos' ? JSON.stringify(v) : v);
      sets.push(`${map[k] ?? k} = $${args.length}`);
    }
    if (!sets.length) throw badRequest('empty_update');
    args.push(id);
    const r = await db.query(
      `UPDATE listings SET ${sets.join(', ')}, updated_at = now() WHERE id = $${args.length} RETURNING ${COLS}`, args);
    return r.rows[0];
  });

  app.delete('/listings/:id', { preHandler: requireAuth(ctx) }, async (req, reply) => {
    const { id } = parse(z.object({ id: z.uuid() }), req.params);
    const r = await db.query(
      `UPDATE listings SET status='removed', updated_at=now()
       WHERE id=$1 AND seller_id=$2 AND status='active' RETURNING id`, [id, me(req).id]);
    if (!r.rowCount) throw notFound();
    return reply.code(204).send();
  });
}
