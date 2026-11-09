// Covoiturage : un conducteur publie un trajet, les passagers réservent des places.
// Le paiement passe par le séquestre ; le conducteur est payé à la confirmation du passager.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { withTx } from '../../db.js';
import { conflict, forbidden, notFound, parse } from '../../lib/errors.js';
import { me, requireAuth } from '../auth/guard.js';
import { findReplay, insertOrder, viewOrder } from '../orders/service.js';
import { idempotencyKey } from '../orders/routes.js';

const city = z.string().trim().min(2).max(60);

export async function carpoolRoutes(app: FastifyInstance, ctx: Ctx) {
  const { db } = ctx;
  const auth = { preHandler: requireAuth(ctx) };
  const idParam = z.object({ id: z.uuid() });

  app.get('/trips', async (req) => {
    const q = parse(z.object({ from: city, to: city, date: z.iso.date().optional() }), req.query);
    const args: unknown[] = [q.from, q.to];
    let dateSql = 'AND t.depart_at > now()';
    if (q.date) { args.push(q.date); dateSql = `AND t.depart_at::date = $3::date AND t.depart_at > now()`; }
    const r = await db.query(
      `SELECT t.id, t.from_city AS "fromCity", t.to_city AS "toCity", t.depart_at AS "departAt",
              t.seats_left AS "seatsLeft", t.price_per_seat_xaf AS "pricePerSeatXaf", t.notes,
              json_build_object('id', u.id, 'displayName', u.display_name) AS driver
       FROM trips t JOIN users u ON u.id=t.driver_id
       WHERE t.status='open' AND t.seats_left > 0 AND lower(t.from_city)=lower($1) AND lower(t.to_city)=lower($2) ${dateSql}
       ORDER BY t.depart_at LIMIT 50`, args);
    return { items: r.rows };
  });

  app.get('/trips/mine', auth, async (req) => {
    const r = await db.query(
      `SELECT id, from_city AS "fromCity", to_city AS "toCity", depart_at AS "departAt", seats_total AS "seatsTotal",
              seats_left AS "seatsLeft", price_per_seat_xaf AS "pricePerSeatXaf", status
       FROM trips WHERE driver_id=$1 ORDER BY depart_at DESC LIMIT 50`, [me(req).id]);
    return { items: r.rows };
  });

  app.post('/trips', auth, async (req, reply) => {
    const b = parse(z.object({
      fromCity: city, toCity: city,
      departAt: z.iso.datetime({ offset: true }),
      seats: z.number().int().min(1).max(8),
      pricePerSeatXaf: z.number().int().positive().max(1_000_000),
      notes: z.string().trim().max(500).default(''),
    }), req.body);
    if (new Date(b.departAt).getTime() < Date.now() + 15 * 60_000) throw conflict('departure_too_soon');
    const r = await db.query<{ id: string }>(
      `INSERT INTO trips (driver_id, from_city, to_city, depart_at, seats_total, seats_left, price_per_seat_xaf, notes)
       VALUES ($1,$2,$3,$4,$5,$5,$6,$7) RETURNING id`,
      [me(req).id, b.fromCity, b.toCity, b.departAt, b.seats, b.pricePerSeatXaf, b.notes]);
    return reply.code(201).send({ id: r.rows[0]!.id });
  });

  app.post('/trips/:id/cancel', auth, async (req) => {
    const { id } = parse(idParam, req.params);
    const r = await db.query(`UPDATE trips SET status='cancelled' WHERE id=$1 AND driver_id=$2 AND status='open'
                              AND NOT EXISTS (SELECT 1 FROM orders WHERE ref_id=$1 AND status IN ('pending_payment','paid','disputed'))
                              RETURNING id`, [id, me(req).id]);
    if (!r.rowCount) throw conflict('trip_not_cancellable');
    return { id, status: 'cancelled' };
  });

  // Réserver des places : verrou sur le trajet, places décrémentées dans la même transaction.
  app.post('/trips/:id/book', auth, async (req, reply) => {
    const { id } = parse(idParam, req.params);
    const { seats } = parse(z.object({ seats: z.number().int().min(1).max(8) }), req.body);
    const buyerId = me(req).id;
    const key = idempotencyKey(req);
    const replay = await findReplay(db, buyerId, key);
    if (replay) return reply.code(200).send(viewOrder(replay));
    const order = await withTx(db, async (tx) => {
      const t = await tx.query<{ driver_id: string; seats_left: number; price_per_seat_xaf: number; status: string;
        depart_at: Date; from_city: string; to_city: string }>(
        'SELECT driver_id, seats_left, price_per_seat_xaf, status, depart_at, from_city, to_city FROM trips WHERE id=$1 FOR UPDATE', [id]);
      const trip = t.rows[0];
      if (!trip) throw notFound('trip_not_found');
      if (trip.driver_id === buyerId) throw forbidden('own_trip');
      if (trip.status !== 'open' || trip.depart_at.getTime() < Date.now()) throw conflict('trip_unavailable');
      if (trip.seats_left < seats) throw conflict('not_enough_seats');
      await tx.query('UPDATE trips SET seats_left = seats_left - $2 WHERE id=$1', [id, seats]);
      const o = await insertOrder(tx, ctx, {
        buyerId, sellerId: trip.driver_id, kind: 'carpool', refId: id, idempotencyKey: key,
        items: [{ name: `${trip.from_city} → ${trip.to_city}`, qty: seats, unitPriceXaf: trip.price_per_seat_xaf }],
        itemPriceXaf: seats * trip.price_per_seat_xaf,
      });
      // Le conducteur est notifié au paiement (voir syncPayment), pas à la simple réservation.
      return o;
    });
    return reply.code(201).send(viewOrder(order));
  });
}
