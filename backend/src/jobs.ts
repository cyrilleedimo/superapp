// Tâches de fond : expiration des commandes impayées, libération automatique du séquestre.
// Un verrou consultatif PostgreSQL garantit qu'une seule instance de l'API les exécute.
import type { Ctx } from './context.js';
import type { OrderService } from './modules/orders/service.js';

export function startJobs(ctx: Ctx, orders: OrderService, log: (m: string) => void): () => void {
  let running = false;
  const tick = async () => {
    if (running) return;
    running = true;
    const client = await ctx.db.connect();
    try {
      const lock = await client.query<{ ok: boolean }>('SELECT pg_try_advisory_lock(424242) AS ok');
      if (!lock.rows[0]?.ok) return;
      try {
        const expired = await orders.expirePending();
        const released = await orders.autoRelease();
        if (expired || released) log(`jobs: ${expired} commande(s) expirée(s), ${released} séquestre(s) libéré(s)`);
      } finally {
        await client.query('SELECT pg_advisory_unlock(424242)');
      }
    } catch (e) {
      log(`jobs: erreur ${(e as Error).message}`);
    } finally {
      client.release();
      running = false;
    }
  };
  const timer = setInterval(tick, 60_000);
  return () => clearInterval(timer);
}
