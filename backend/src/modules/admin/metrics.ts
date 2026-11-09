// Tableau de bord admin : totaux actuels + évolution sur les 14 derniers jours
// (inscriptions, annonces créées, commandes et chiffre d'affaires). Lecture seule,
// réservé au rôle admin.
import type { FastifyInstance } from 'fastify';
import type { Ctx } from '../../context.js';
import { requireAuth } from '../auth/guard.js';

const DAYS = 14;

export async function adminMetricsRoutes(app: FastifyInstance, ctx: Ctx) {
  const { db } = ctx;

  app.get('/admin/metrics', { preHandler: requireAuth(ctx, ['admin']) }, async () => {
    // generate_series garantit un point par jour même sans activité ce jour-là
    // (sinon un jour à zéro disparaîtrait du graphique au lieu d'y apparaître à zéro).
    const [users, listings, orders, totals] = await Promise.all([
      db.query(`
        SELECT to_char(d, 'YYYY-MM-DD') AS day, count(u.id)::int AS count
        FROM generate_series((current_date - ${DAYS - 1}), current_date, interval '1 day') d
        LEFT JOIN users u ON u.created_at::date = d
        GROUP BY d ORDER BY d`),
      db.query(`
        SELECT to_char(d, 'YYYY-MM-DD') AS day, count(l.id)::int AS count
        FROM generate_series((current_date - ${DAYS - 1}), current_date, interval '1 day') d
        LEFT JOIN listings l ON l.created_at::date = d
        GROUP BY d ORDER BY d`),
      db.query(`
        SELECT to_char(d, 'YYYY-MM-DD') AS day, count(o.id)::int AS count,
               coalesce(sum(o.total_xaf) FILTER (WHERE o.status <> 'cancelled'), 0)::bigint AS "revenueXaf"
        FROM generate_series((current_date - ${DAYS - 1}), current_date, interval '1 day') d
        LEFT JOIN orders o ON o.created_at::date = d
        GROUP BY d ORDER BY d`),
      db.query(`SELECT
          (SELECT count(*) FROM users)::int AS "usersTotal",
          (SELECT count(*) FROM listings WHERE status = 'active')::int AS "listingsActive",
          (SELECT count(*) FROM orders)::int AS "ordersTotal",
          (SELECT coalesce(sum(total_xaf), 0) FROM orders WHERE status <> 'cancelled')::bigint AS "revenueTotalXaf",
          (SELECT count(*) FROM payouts WHERE status = 'requested')::int AS "payoutsPending",
          (SELECT coalesce(sum(amount_xaf), 0) FROM payouts WHERE status = 'requested')::bigint AS "payoutsPendingXaf"`),
    ]);
    return {
      days: { users: users.rows, listings: listings.rows, orders: orders.rows },
      totals: totals.rows[0],
    };
  });
}
