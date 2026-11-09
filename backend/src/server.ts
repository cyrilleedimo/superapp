// Point d'entrée : charge la config, applique les migrations, démarre l'API.
import { loadConfig, type Config } from './config.js';
import { createPool } from './db.js';
import { migrate } from './migrate.js';
import { buildApp } from './app.js';
import type { Ctx } from './context.js';
import { startJobs } from './jobs.js';
import { makeOrderService } from './modules/orders/service.js';
import { MemorySmsSender } from './modules/auth/sms.js';
import { exportAll, exportUser } from './lib/userExport.js';
import { fileURLToPath } from 'node:url';
import { makeTokenService } from './modules/auth/tokens.js';
import { NotchPayProvider, SandboxProvider } from './modules/payments/provider.js';

export function buildContext(config: Config): Ctx {
  if (config.NODE_ENV === 'production') {
    // [SMS PROVIDER] : brancher un vrai fournisseur avant la mise en production.
    throw new Error('Aucun fournisseur SMS de production configuré (voir modules/auth/sms.ts)');
  }
  const payments = config.PAYMENT_PROVIDER === 'notchpay'
    ? new NotchPayProvider(config.NOTCHPAY_API_KEY!, config.NOTCHPAY_WEBHOOK_HASH!)
    : new SandboxProvider(config.SANDBOX_WEBHOOK_SECRET);
  const sms = new MemorySmsSender();
  // En développement, affiche les SMS dans la console pour pouvoir tester l'OTP.
  const origSend = sms.send.bind(sms);
  sms.send = async (phone, text) => { await origSend(phone, text); console.log(`[SMS dev] ${phone}: ${text}`); };
  return {
    config,
    db: createPool(config.DATABASE_URL),
    sms,
    payments,
    tokens: makeTokenService(config.JWT_SECRET, config.ACCESS_TOKEN_TTL_SEC),
  };
}

/** Démarre l'API. `onStop` permet au lanceur local d'arrêter proprement la base embarquée. */
export async function main(onStop?: () => Promise<void>) {
  const config = loadConfig();
  const ctx = buildContext(config);
  await migrate(ctx.db, (m) => console.log(m));
  const app = await buildApp(ctx);

  // Miroir lisible par utilisateur (Bureau\Base de données\Utilisateurs) si EXPORT_DIR est défini.
  let exportTimer: NodeJS.Timeout | undefined;
  if (config.EXPORT_DIR) {
    const dir = config.EXPORT_DIR;
    app.addHook('onResponse', async (req, reply) => {
      if (req.method !== 'GET' && req.user && reply.statusCode < 400) {
        exportUser(ctx.db, dir, req.user.id).catch((e) => app.log.warn(`export: ${(e as Error).message}`));
      }
    });
    const runAll = () => exportAll(ctx.db, dir).catch((e) => app.log.warn(`export: ${(e as Error).message}`));
    exportTimer = setInterval(runAll, 30_000);
    void runAll();
    app.log.info(`fichiers utilisateurs : ${dir}`);
  }

  await app.listen({ port: config.PORT, host: '0.0.0.0' });
  const stopJobs = config.DISABLE_JOBS === 'true' ? () => {} : startJobs(ctx, makeOrderService(ctx), (m) => app.log.info(m));
  let stopping = false;
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    stopJobs();
    if (exportTimer) clearInterval(exportTimer);
    await app.close();
    await ctx.db.end();
    if (onStop) await onStop();
    process.exit(0);
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

// Lancement direct (`node dist/src/server.js`), pas quand importé par le lanceur local.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => { console.error(e); process.exit(1); });
}
