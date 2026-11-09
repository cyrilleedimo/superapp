// Grand livre en partie double. Chaque écriture est équilibrée (vérifié aussi par
// un trigger PostgreSQL différé) et le livre est en ajout seul.
import { randomUUID } from 'node:crypto';
import type { Db, Tx } from '../../db.js';

export interface Line { account: string; amountXaf: number }

export const walletAccount = (userId: string) => `wallet:${userId}`;

async function accountId(tx: Tx, code: string): Promise<string> {
  const kind = code.startsWith('wallet:') ? 'liability' : null;
  if (kind) {
    await tx.query(`INSERT INTO ledger_accounts (code, kind) VALUES ($1,$2) ON CONFLICT (code) DO NOTHING`, [code, kind]);
  }
  const r = await tx.query<{ id: string }>('SELECT id FROM ledger_accounts WHERE code=$1', [code]);
  if (!r.rows[0]) throw new Error(`compte de grand livre inconnu : ${code}`);
  return r.rows[0].id;
}

/** Écrit une transaction équilibrée. À appeler DANS une transaction SQL. */
export async function post(tx: Tx, p: { memo: string; orderId?: string; lines: Line[] }): Promise<string> {
  const sum = p.lines.reduce((s, l) => s + l.amountXaf, 0);
  if (sum !== 0) throw new Error(`écriture déséquilibrée (${sum})`);
  if (p.lines.some((l) => !Number.isSafeInteger(l.amountXaf) || l.amountXaf === 0)) throw new Error('montant invalide');
  const txnId = randomUUID();
  for (const l of p.lines) {
    await tx.query(
      `INSERT INTO ledger_entries (txn_id, account_id, amount_xaf, order_id, memo) VALUES ($1,$2,$3,$4,$5)`,
      [txnId, await accountId(tx, l.account), l.amountXaf, p.orderId ?? null, p.memo]);
  }
  return txnId;
}

/** Solde signé d'un compte (débits positifs, crédits négatifs). */
export async function balance(q: Db | Tx, code: string): Promise<number> {
  const r = await q.query<{ s: number }>(
    `SELECT coalesce(sum(e.amount_xaf),0)::bigint AS s
     FROM ledger_entries e JOIN ledger_accounts a ON a.id = e.account_id WHERE a.code=$1`, [code]);
  return Number(r.rows[0]?.s ?? 0);
}
