// Assistant « décrire avec l'IA » : à partir de photos déjà uploadées par le vendeur
// (donc déjà vérifiées, ré-encodées et débarrassées de leurs métadonnées par /media),
// propose un titre + une description. Le vendeur reste libre de tout corriger avant
// de publier — ce n'est qu'une suggestion, jamais une donnée de confiance.
import { readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { AppError, parse } from '../../lib/errors.js';
import { me, requireAuth } from '../auth/guard.js';
import { suggestListingText } from './gemini.js';

const MAX_PHOTOS = 5;

export async function aiRoutes(app: FastifyInstance, ctx: Ctx) {
  const { db, config } = ctx;
  const dir = resolve(config.UPLOAD_DIR);

  app.post('/listings/suggest-description', {
    preHandler: requireAuth(ctx),
    config: { rateLimit: { max: 10, timeWindow: '1 minute' } },
  }, async (req) => {
    if (!config.GEMINI_API_KEY) throw new AppError(503, 'ai_not_configured');
    const { photoIds } = parse(z.object({ photoIds: z.array(z.uuid()).min(1).max(MAX_PHOTOS) }), req.body);

    const r = await db.query<{ storage_key: string; mime: string }>(
      'SELECT storage_key, mime FROM media WHERE id = ANY($1) AND owner_id = $2', [photoIds, me(req).id]);
    if (!r.rows.length) throw new AppError(404, 'photos_not_found');

    const images = await Promise.all(r.rows.map(async (row) => ({
      mime: row.mime,
      base64: (await readFile(join(dir, row.storage_key))).toString('base64'),
    })));

    try {
      return await suggestListingText(config.GEMINI_API_KEY, config.GEMINI_MODEL, images);
    } catch (e) {
      req.log.warn(`gemini: ${(e as Error).message}`);
      throw new AppError(502, 'ai_unavailable');
    }
  });
}
