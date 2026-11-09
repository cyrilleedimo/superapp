// VTC (courses en ville) : chauffeurs vérifiés par un admin, estimation du prix,
// attribution au premier chauffeur proche qui accepte, suivi de statut.
// Paiement des courses : espèces en Phase 2 (paiement in-app après pré-autorisation : Phase 4).
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { withTx } from '../../db.js';
import { AppError, conflict, forbidden, notFound, parse } from '../../lib/errors.js';
import { audit } from '../../lib/audit.js';
import { notify } from '../../lib/notify.js';
import { me, requireAuth } from '../auth/guard.js';

const lat = z.number().min(-90).max(90);
const lng = z.number().min(-180).max(180);

/** Distance à vol d'oiseau (formule de haversine), en km. Estimation, pas un itinéraire routier. */
export function haversineKm(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const R = 6371, rad = Math.PI / 180;
  const dLat = (bLat - aLat) * rad, dLng = (bLng - aLng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(aLat * rad) * Math.cos(bLat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

const RIDE_COLS = `id, rider_id AS "riderId", driver_id AS "driverId", pickup_text AS "pickupText",
  pickup_lat AS "pickupLat", pickup_lng AS "pickupLng", dropoff_text AS "dropoffText",
  dropoff_lat AS "dropoffLat", dropoff_lng AS "dropoffLng", distance_km::float AS "distanceKm",
  fare_xaf AS "fareXaf", payment, status, created_at AS "createdAt"`;

export async function rideRoutes(app: FastifyInstance, ctx: Ctx) {
  const { db, config } = ctx;
  const auth = { preHandler: requireAuth(ctx) };
  const admin = { preHandler: requireAuth(ctx, ['admin']) };
  const idParam = z.object({ id: z.uuid() });

  function quote(pLat: number, pLng: number, dLat: number, dLng: number) {
    if (config.RIDE_BASE_XAF === undefined || config.RIDE_PER_KM_XAF === undefined) {
      throw new AppError(503, 'rides_not_configured');
    }
    const km = Math.round(haversineKm(pLat, pLng, dLat, dLng) * 100) / 100;
    if (km < 0.2) throw new AppError(400, 'ride_too_short');
    if (km > 100) throw new AppError(400, 'ride_too_long');
    return { distanceKm: km, fareXaf: Math.ceil(config.RIDE_BASE_XAF + km * config.RIDE_PER_KM_XAF) };
  }

  // ------------------------------------------------------------ Chauffeurs
  app.post('/drivers/apply', auth, async (req, reply) => {
    const b = parse(z.object({ vehicle: z.string().trim().min(2).max(80), plate: z.string().trim().min(3).max(20) }), req.body);
    await db.query(
      `INSERT INTO driver_profiles (user_id, vehicle, plate) VALUES ($1,$2,$3)
       ON CONFLICT (user_id) DO UPDATE SET vehicle=EXCLUDED.vehicle, plate=EXCLUDED.plate, verified=false, online=false, updated_at=now()`,
      [me(req).id, b.vehicle, b.plate]);
    return reply.code(201).send({ status: 'pending_verification' });
  });

  app.get('/drivers/me', auth, async (req) => {
    const r = await db.query(
      `SELECT vehicle, plate, verified, online FROM driver_profiles WHERE user_id=$1`, [me(req).id]);
    return r.rows[0] ?? { applied: false };
  });

  app.post('/drivers/me/status', { ...auth, config: { rateLimit: { max: 120, timeWindow: '1 minute' } } }, async (req) => {
    const b = parse(z.object({ online: z.boolean(), lat: lat.optional(), lng: lng.optional() }), req.body);
    if (b.online && (b.lat === undefined || b.lng === undefined)) throw new AppError(400, 'location_required');
    const r = await db.query(
      `UPDATE driver_profiles SET online=$2, lat=coalesce($3, lat), lng=coalesce($4, lng), updated_at=now()
       WHERE user_id=$1 AND verified RETURNING online`, [me(req).id, b.online, b.lat ?? null, b.lng ?? null]);
    if (!r.rowCount) throw forbidden('driver_not_verified');
    return { online: b.online };
  });

  app.get('/admin/drivers', admin, async () => {
    const r = await db.query(
      `SELECT d.user_id AS "userId", u.display_name AS "displayName", u.phone, d.vehicle, d.plate, d.verified
       FROM driver_profiles d JOIN users u ON u.id=d.user_id ORDER BY d.verified, d.updated_at DESC LIMIT 200`);
    return { items: r.rows };
  });

  app.post('/admin/drivers/:id/verify', admin, async (req) => {
    const { id } = parse(idParam, req.params);
    const { verified } = parse(z.object({ verified: z.boolean() }), req.body);
    const r = await db.query('UPDATE driver_profiles SET verified=$2, online=false, updated_at=now() WHERE user_id=$1', [id, verified]);
    if (!r.rowCount) throw notFound();
    await audit(db, { actorId: me(req).id, action: verified ? 'driver.verified' : 'driver.revoked', entity: 'user', entityId: id });
    await notify(db, id, verified ? 'Compte chauffeur validé' : 'Compte chauffeur suspendu',
      verified ? 'Tu peux passer en ligne et accepter des courses.' : 'Contacte le support pour plus d\'informations.');
    return { userId: id, verified };
  });

  // ---------------------------------------------------------------- Courses
  const point = z.object({ text: z.string().trim().min(2).max(200), lat, lng });

  app.post('/rides/estimate', async (req) => {
    const b = parse(z.object({ pickup: point, dropoff: point }), req.body);
    return quote(b.pickup.lat, b.pickup.lng, b.dropoff.lat, b.dropoff.lng);
  });

  app.post('/rides', { ...auth, config: { rateLimit: { max: 10, timeWindow: '1 minute' } } }, async (req, reply) => {
    const b = parse(z.object({ pickup: point, dropoff: point }), req.body);
    const q = quote(b.pickup.lat, b.pickup.lng, b.dropoff.lat, b.dropoff.lng);
    try {
      const r = await db.query(
        `INSERT INTO rides (rider_id, pickup_text, pickup_lat, pickup_lng, dropoff_text, dropoff_lat, dropoff_lng, distance_km, fare_xaf)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING ${RIDE_COLS}`,
        [me(req).id, b.pickup.text, b.pickup.lat, b.pickup.lng, b.dropoff.text, b.dropoff.lat, b.dropoff.lng, q.distanceKm, q.fareXaf]);
      return reply.code(201).send(r.rows[0]);
    } catch (e) {
      if ((e as { code?: string }).code === '23505') throw conflict('ride_already_active');
      throw e;
    }
  });

  // Course active de l'utilisateur, qu'il soit passager ou chauffeur.
  app.get('/rides/current', auth, async (req) => {
    const r = await db.query(
      `SELECT ${RIDE_COLS},
              (SELECT json_build_object('displayName', u.display_name, 'phone', u.phone, 'vehicle', d.vehicle, 'plate', d.plate)
               FROM users u JOIN driver_profiles d ON d.user_id=u.id WHERE u.id = rides.driver_id) AS driver
       FROM rides WHERE (rider_id=$1 OR driver_id=$1) AND status IN ('requested','accepted','arrived','in_progress')
       ORDER BY created_at DESC LIMIT 1`, [me(req).id]);
    return { ride: r.rows[0] ?? null };
  });

  // Chauffeur en ligne : demandes récentes à proximité.
  app.get('/rides/nearby', auth, async (req) => {
    const d = await db.query<{ lat: number | null; lng: number | null }>(
      'SELECT lat, lng FROM driver_profiles WHERE user_id=$1 AND verified AND online', [me(req).id]);
    const pos = d.rows[0];
    if (!pos || pos.lat === null || pos.lng === null) throw forbidden('driver_not_online');
    const r = await db.query<{ pickupLat: number; pickupLng: number }>(
      `SELECT ${RIDE_COLS} FROM rides WHERE status='requested' AND rider_id <> $1
       AND created_at > now() - interval '15 minutes' ORDER BY created_at LIMIT 100`, [me(req).id]);
    const items = r.rows
      .map((x) => ({ ...x, pickupDistanceKm: Math.round(haversineKm(pos.lat!, pos.lng!, x.pickupLat, x.pickupLng) * 10) / 10 }))
      .filter((x) => x.pickupDistanceKm <= config.RIDE_DISPATCH_RADIUS_KM)
      .sort((a, b) => a.pickupDistanceKm - b.pickupDistanceKm)
      .slice(0, 20);
    return { items };
  });

  // Premier chauffeur qui accepte : verrou de ligne, une seule attribution possible.
  app.post('/rides/:id/accept', auth, async (req) => {
    const { id } = parse(idParam, req.params);
    const driverId = me(req).id;
    try {
      return await withTx(db, async (tx) => {
        const d = await tx.query('SELECT 1 FROM driver_profiles WHERE user_id=$1 AND verified AND online', [driverId]);
        if (!d.rowCount) throw forbidden('driver_not_online');
        const r = await tx.query<{ status: string; rider_id: string }>('SELECT status, rider_id FROM rides WHERE id=$1 FOR UPDATE', [id]);
        const ride = r.rows[0];
        if (!ride) throw notFound();
        if (ride.rider_id === driverId) throw forbidden('own_ride');
        if (ride.status !== 'requested') throw conflict('ride_already_taken');
        const u = await tx.query(`UPDATE rides SET driver_id=$2, status='accepted', updated_at=now() WHERE id=$1 RETURNING ${RIDE_COLS}`, [id, driverId]);
        await notify(tx, ride.rider_id, 'Chauffeur en route', 'Un chauffeur a accepté ta course.', '/rides');
        return u.rows[0];
      });
    } catch (e) {
      if ((e as { code?: string }).code === '23505') throw conflict('driver_already_on_ride');
      throw e;
    }
  });

  app.post('/rides/:id/status', auth, async (req) => {
    const { id } = parse(idParam, req.params);
    const { status } = parse(z.object({ status: z.enum(['arrived', 'in_progress', 'completed']) }), req.body);
    const prev: Record<string, string> = { arrived: 'accepted', in_progress: 'arrived', completed: 'in_progress' };
    return withTx(db, async (tx) => {
      const r = await tx.query<{ status: string; driver_id: string | null; rider_id: string }>(
        'SELECT status, driver_id, rider_id FROM rides WHERE id=$1 FOR UPDATE', [id]);
      const ride = r.rows[0];
      if (!ride || ride.driver_id !== me(req).id) throw notFound();
      if (ride.status !== prev[status]) throw conflict('invalid_transition');
      const u = await tx.query(`UPDATE rides SET status=$2, updated_at=now() WHERE id=$1 RETURNING ${RIDE_COLS}`, [id, status]);
      const msg: Record<string, string> = {
        arrived: 'Ton chauffeur est arrivé au point de départ.',
        in_progress: 'Course démarrée. Bon trajet !',
        completed: 'Course terminée. Merci d\'avoir voyagé avec nous.',
      };
      await notify(tx, ride.rider_id, 'Course', msg[status]!, '/rides');
      if (status === 'completed') await audit(tx, { actorId: ride.driver_id, action: 'ride.completed', entity: 'ride', entityId: id });
      return u.rows[0];
    });
  });

  app.post('/rides/:id/cancel', auth, async (req) => {
    const { id } = parse(idParam, req.params);
    const userId = me(req).id;
    return withTx(db, async (tx) => {
      const r = await tx.query<{ status: string; driver_id: string | null; rider_id: string }>(
        'SELECT status, driver_id, rider_id FROM rides WHERE id=$1 FOR UPDATE', [id]);
      const ride = r.rows[0];
      if (!ride || (ride.rider_id !== userId && ride.driver_id !== userId)) throw notFound();
      if (!['requested', 'accepted', 'arrived'].includes(ride.status)) throw conflict('ride_not_cancellable');
      await tx.query(`UPDATE rides SET status='cancelled', updated_at=now() WHERE id=$1`, [id]);
      const other = userId === ride.rider_id ? ride.driver_id : ride.rider_id;
      if (other) await notify(tx, other, 'Course annulée', 'La course a été annulée.', '/rides');
      return { id, status: 'cancelled' };
    });
  });
}
