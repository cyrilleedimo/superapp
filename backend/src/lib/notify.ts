// Notifications in-app (cloche). Le push mobile (FCM) se branchera ici : [PUSH PROVIDER].
import type { Db, Tx } from '../db.js';

export async function notify(q: Db | Tx, userId: string, title: string, body: string, link?: string): Promise<void> {
  await q.query('INSERT INTO notifications (user_id, title, body, link) VALUES ($1,$2,$3,$4)',
    [userId, title.slice(0, 120), body.slice(0, 500), link ?? null]);
}
