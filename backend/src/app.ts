// Assemblage de l'application HTTP : sécurité transversale + modules métier.
import Fastify, { type FastifyInstance } from 'fastify';
import helmet from '@fastify/helmet';
import cors from '@fastify/cors';
import rateLimit from '@fastify/rate-limit';
import type { Ctx } from './context.js';
import { AppError } from './lib/errors.js';
import { authRoutes } from './modules/auth/routes.js';
import { marketplaceRoutes } from './modules/marketplace/routes.js';
import { orderRoutes } from './modules/orders/routes.js';
import { makeOrderService } from './modules/orders/service.js';
import { mediaRoutes } from './modules/media/routes.js';
import { messagingRoutes } from './modules/messaging/routes.js';
import { accountRoutes } from './modules/account/routes.js';
import { carpoolRoutes } from './modules/carpool/routes.js';
import { rideRoutes } from './modules/rides/routes.js';
import { storeRoutes } from './modules/stores/routes.js';
import { travelRoutes } from './modules/travel/routes.js';
import { adminMetricsRoutes } from './modules/admin/metrics.js';
import { aiRoutes } from './modules/ai/routes.js';

export async function buildApp(ctx: Ctx): Promise<FastifyInstance> {
  const app = Fastify({
    logger: ctx.config.NODE_ENV === 'test' ? false : {
      level: 'info',
      // Jamais de secrets dans les journaux.
      redact: ['req.headers.authorization', 'req.headers["x-notch-signature"]', 'req.headers["x-sandbox-signature"]'],
    },
    bodyLimit: 256 * 1024,
    // N'accepte X-Forwarded-For que du nombre de proxys déclaré (anti-contournement du rate limit).
    trustProxy: (_addr: string, hop: number) => hop < ctx.config.TRUST_PROXY_HOPS,
  });

  // Corps JSON gardé aussi en brut : indispensable pour vérifier les signatures de webhook.
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (req, body, done) => {
    const raw = body as string;
    req.rawBody = raw;
    if (raw.length === 0) return done(null, {});
    try { done(null, JSON.parse(raw)); } catch { done(new AppError(400, 'invalid_json'), undefined); }
  });

  await app.register(helmet, { contentSecurityPolicy: false }); // API JSON pure
  await app.register(cors, {
    origin: ctx.config.CORS_ORIGINS ? ctx.config.CORS_ORIGINS.split(',').map((s) => s.trim()) : false,
  });
  await app.register(rateLimit, { max: 300, timeWindow: '1 minute' });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof AppError) {
      return reply.code(err.status).send({ error: err.code, message: err.status < 500 ? err.message : undefined });
    }
    const status = (err as { statusCode?: number }).statusCode;
    if (status === 429) return reply.code(429).send({ error: 'rate_limited' });
    if (status && status < 500) return reply.code(status).send({ error: 'bad_request' });
    req.log.error(err);
    return reply.code(500).send({ error: 'internal_error' }); // aucun détail interne exposé
  });

  app.get('/health', async () => ({ ok: true }));
  await authRoutes(app, ctx);
  await marketplaceRoutes(app, ctx);
  await orderRoutes(app, ctx, makeOrderService(ctx));
  await mediaRoutes(app, ctx);
  await messagingRoutes(app, ctx);
  await accountRoutes(app, ctx);
  await carpoolRoutes(app, ctx);
  await rideRoutes(app, ctx);
  await storeRoutes(app, ctx);
  await travelRoutes(app, null); // [TRAVEL API PARTNER] : brancher ici une implémentation de TravelProvider
  await adminMetricsRoutes(app, ctx);
  await aiRoutes(app, ctx);
  return app;
}
