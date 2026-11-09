// Export lisible : un fichier JSON par utilisateur, nommé avec le nom qu'il a saisi,
// dans EXPORT_DIR (ex. Bureau\Base de données\Utilisateurs).
// La base PostgreSQL reste la SOURCE DE VÉRITÉ : ces fichiers sont un miroir en
// lecture, réécrits automatiquement. Les modifier à la main ne change rien dans l'app.
import { mkdir, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { Db } from '../db.js';
import { balance, walletAccount } from '../modules/ledger/ledger.js';

const WINDOWS_RESERVED = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i;

/** Transforme un nom saisi en nom de fichier Windows sûr (sans chemin ni caractère interdit). */
export function safeFileBase(name: string): string {
  let s = name
    .normalize('NFC')
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, ' ') // caractères interdits par Windows
    .replace(/\.+/g, ' ')                        // pas de « .. » ni d'extension piégée
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 60)
    .trim();
  if (!s || WINDOWS_RESERVED.test(s)) s = `Utilisateur ${s}`.trim();
  return s;
}

/** Réserve un nom unique pour l'utilisateur (« Paul », « Paul (2) »…), stable dans le temps. */
async function fileNameFor(db: Db, userId: string, displayName: string): Promise<string> {
  const existing = await db.query<{ file_name: string }>('SELECT file_name FROM user_export_files WHERE user_id=$1', [userId]);
  if (existing.rows[0]) return existing.rows[0].file_name;
  const base = safeFileBase(displayName);
  for (let n = 1; n < 1000; n++) {
    const candidate = n === 1 ? `${base}.json` : `${base} (${n}).json`;
    const r = await db.query(
      `INSERT INTO user_export_files (user_id, file_name) VALUES ($1,$2) ON CONFLICT DO NOTHING RETURNING file_name`,
      [userId, candidate]);
    if (r.rowCount) return candidate;
    const again = await db.query<{ file_name: string }>('SELECT file_name FROM user_export_files WHERE user_id=$1', [userId]);
    if (again.rows[0]) return again.rows[0].file_name; // créé en parallèle
  }
  throw new Error('impossible de réserver un nom de fichier');
}

export async function exportUser(db: Db, dir: string, userId: string): Promise<string | null> {
  const u = await db.query<{ display_name: string }>(
    `SELECT display_name FROM users WHERE id=$1`, [userId]);
  if (!u.rows[0]) return null;
  const q = async (sql: string) => (await db.query(sql, [userId])).rows;
  const [profile] = await q(`SELECT id, display_name AS "nom", phone AS "telephone", email, role, status AS "statut",
                                    created_at AS "inscritLe" FROM users WHERE id=$1`);
  const data = {
    _avertissement: 'Copie lisible générée automatiquement. La base de données reste la référence : modifier ce fichier ne change rien dans l\'application.',
    generéLe: new Date().toISOString(),
    profil: profile,
    porteMonnaieXaf: -(await balance(db, walletAccount(userId))),
    annonces: await q(`SELECT id, title AS "titre", price_xaf AS "prixXaf", status AS "statut", city AS "ville", created_at AS "creeLe"
                       FROM listings WHERE seller_id=$1 ORDER BY created_at DESC`),
    achats: await q(`SELECT id, kind AS "service", total_xaf AS "totalXaf", status AS "statut", items AS "articles", created_at AS "creeLe"
                     FROM orders WHERE buyer_id=$1 ORDER BY created_at DESC`),
    ventes: await q(`SELECT id, kind AS "service", item_price_xaf AS "montantXaf", status AS "statut", items AS "articles", created_at AS "creeLe"
                     FROM orders WHERE seller_id=$1 ORDER BY created_at DESC`),
    trajetsPublies: await q(`SELECT id, from_city AS "depart", to_city AS "arrivee", depart_at AS "date", seats_left AS "placesLibres", status AS "statut"
                             FROM trips WHERE driver_id=$1 ORDER BY depart_at DESC`),
    courses: await q(`SELECT id, CASE WHEN rider_id=$1 THEN 'passager' ELSE 'chauffeur' END AS "role", fare_xaf AS "prixXaf",
                             status AS "statut", created_at AS "creeLe" FROM rides WHERE rider_id=$1 OR driver_id=$1 ORDER BY created_at DESC LIMIT 200`),
    commerces: await q(`SELECT id, kind AS "type", name AS "nom", city AS "ville", approved AS "valide" FROM stores WHERE owner_id=$1`),
    retraits: await q(`SELECT id, amount_xaf AS "montantXaf", channel AS "canal", status AS "statut", created_at AS "demandeLe"
                       FROM payouts WHERE user_id=$1 ORDER BY created_at DESC`),
  };
  const name = await fileNameFor(db, userId, u.rows[0].display_name);
  await mkdir(dir, { recursive: true });
  // Écriture atomique : fichier temporaire puis renommage (jamais de fichier à moitié écrit).
  const tmp = join(dir, `.${name}.${process.pid}.tmp`);
  await writeFile(tmp, JSON.stringify(data, null, 2), 'utf8');
  await rename(tmp, join(dir, name));
  await db.query('UPDATE user_export_files SET exported_at=now() WHERE user_id=$1', [userId]);
  return name;
}

/** Réexporte tous les utilisateurs (tâche périodique). Pensé pour un pilote (milliers d'utilisateurs max). */
export async function exportAll(db: Db, dir: string): Promise<number> {
  const ids = (await db.query<{ id: string }>(`SELECT id FROM users WHERE status <> 'suspended'`)).rows;
  for (const { id } of ids) await exportUser(db, dir, id);
  return ids.length;
}
