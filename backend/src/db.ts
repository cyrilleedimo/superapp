// Accès PostgreSQL : un pool partagé + un utilitaire de transaction.
import pg from 'pg';

// bigint (int8) -> number : sûr ici car les montants XAF restent < 2^53.
pg.types.setTypeParser(20, (v) => Number(v));

export type Db = pg.Pool;
export type Tx = pg.PoolClient;

export function createPool(url: string): Db {
  const pool = new pg.Pool({ connectionString: url, max: 10, idleTimeoutMillis: 30_000 });
  // Une connexion inactive coupée par la base (redémarrage, arrêt) ne doit pas faire planter l'API.
  pool.on('error', (err) => console.warn(`postgres: connexion inactive perdue (${err.message})`));
  return pool;
}

/** Exécute `fn` dans une transaction ; ROLLBACK automatique en cas d'erreur. */
export async function withTx<T>(db: Db, fn: (tx: Tx) => Promise<T>): Promise<T> {
  const client = await db.connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}
