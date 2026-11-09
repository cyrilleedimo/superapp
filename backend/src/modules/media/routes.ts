// Upload d'images sécurisé : type vérifié par signature binaire, image RÉ-ENCODÉE
// (supprime EXIF/GPS et tout contenu caché), taille plafonnée, servie en WebP.
// Stockage disque en dev ; [OBJECT STORAGE] (S3 compatible) en production.
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import type { FastifyInstance } from 'fastify';
import sharp from 'sharp';
import { z } from 'zod';
import type { Ctx } from '../../context.js';
import { AppError, notFound, parse } from '../../lib/errors.js';
import { randomToken, sha256Hex } from '../../lib/crypto.js';
import { me, requireAuth } from '../auth/guard.js';

const MAX_BYTES = 5 * 1024 * 1024;
const MAX_SIDE = 1600;

function sniff(buf: Buffer): string | null {
  if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf.length > 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (buf.length > 12 && buf.subarray(0, 4).toString() === 'RIFF' && buf.subarray(8, 12).toString() === 'WEBP') return 'image/webp';
  return null;
}

export async function mediaRoutes(app: FastifyInstance, ctx: Ctx) {
  const dir = resolve(ctx.config.UPLOAD_DIR);
  await mkdir(dir, { recursive: true });

  app.addContentTypeParser(['image/jpeg', 'image/png', 'image/webp'], { parseAs: 'buffer', bodyLimit: MAX_BYTES },
    (_req, body, done) => done(null, body));

  app.post('/media', { preHandler: requireAuth(ctx), config: { rateLimit: { max: 30, timeWindow: '1 minute' } } },
    async (req, reply) => {
      const buf = req.body;
      if (!Buffer.isBuffer(buf) || !sniff(buf)) throw new AppError(415, 'unsupported_image');
      let out: Buffer;
      try {
        out = await sharp(buf, { limitInputPixels: 40_000_000 })
          .rotate()                                    // applique l'orientation EXIF puis l'efface
          .resize(MAX_SIDE, MAX_SIDE, { fit: 'inside', withoutEnlargement: true })
          .webp({ quality: 80 })                       // ré-encodage : métadonnées supprimées
          .toBuffer();
      } catch {
        throw new AppError(415, 'unreadable_image');
      }
      const key = `${randomToken(18)}.webp`;
      await writeFile(join(dir, key), out, { flag: 'wx' });
      const r = await ctx.db.query<{ id: string }>(
        `INSERT INTO media (owner_id, mime, bytes, sha256, storage_key) VALUES ($1,'image/webp',$2,$3,$4) RETURNING id`,
        [me(req).id, out.length, sha256Hex(out), key]);
      const id = r.rows[0]!.id;
      return reply.code(201).send({ id, url: `${ctx.config.PUBLIC_BASE_URL}/media/${id}` });
    });

  app.get('/media/:id', async (req, reply) => {
    const { id } = parse(z.object({ id: z.uuid() }), req.params);
    const r = await ctx.db.query<{ storage_key: string; mime: string }>('SELECT storage_key, mime FROM media WHERE id=$1', [id]);
    const m = r.rows[0];
    if (!m || !/^[A-Za-z0-9_-]+\.webp$/.test(m.storage_key)) throw notFound();
    const data = await readFile(join(dir, m.storage_key)).catch(() => null);
    if (!data) throw notFound();
    return reply.type(m.mime).header('Cache-Control', 'public, max-age=31536000, immutable').send(data);
  });
}
