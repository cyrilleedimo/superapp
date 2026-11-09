// Applique les fichiers db/migrations/*.sql dans l'ordre, une seule fois chacun.
import { readdir, readFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { Db } from './db.js';
import { createPool, withTx } from './db.js';

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'db', 'migrations');

export async function migrate(db: Db, log: (m: string) => void = () => {}): Promise<void> {
  await db.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
    name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  const done = new Set((await db.query<{ name: string }>('SELECT name FROM schema_migrations')).rows.map((r) => r.name));
  const files = (await readdir(MIGRATIONS_DIR)).filter((f) => f.endsWith('.sql')).sort();
  for (const f of files) {
    if (done.has(f)) continue;
    const sql = await readFile(join(MIGRATIONS_DIR, f), 'utf8');
    await withTx(db, async (tx) => {
      await tx.query(sql);
      await tx.query('INSERT INTO schema_migrations (name) VALUES ($1)', [f]);
    });
    log(`migration appliquée : ${f}`);
  }
}

// Exécution directe : `npm run migrate`
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error('DATABASE_URL manquant');
  const db = createPool(url);
  migrate(db, console.log).then(() => db.end());
}
