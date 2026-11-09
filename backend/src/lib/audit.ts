// Journal d'audit : toute action sensible (connexion, paiement, litige) laisse une trace.
import type { Db, Tx } from '../db.js';

export async function audit(
  q: Db | Tx,
  e: { actorId?: string | null; action: string; entity: string; entityId?: string; meta?: object; ip?: string },
): Promise<void> {
  await q.query(
    `INSERT INTO audit_log (actor_id, action, entity, entity_id, meta, ip) VALUES ($1,$2,$3,$4,$5,$6)`,
    [e.actorId ?? null, e.action, e.entity, e.entityId ?? null, JSON.stringify(e.meta ?? {}), e.ip ?? null],
  );
}
