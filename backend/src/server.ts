// Point d'entrée : charge la config, applique les migrations, démarre l'API.
import { loadConfig, type Config } from './config.js';
import { createPool } from './db.js';
import { migrate } from './migrate.js';
import { buildApp } from './app.js';
import type { Ctx } from './context.js';
import { MemorySmsSender } from './modules/auth/sms.js';
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

async function main() {
  const config = loadConfig();
  const ctx = buildContext(config);
  await migrate(ctx.db, (m) => console.log(m));
  const app = await buildApp(ctx);
  await app.listen({ port: config.PORT, host: '0.0.0.0' });
  const stop = async () => { await app.close(); await ctx.db.end(); process.exit(0); };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

main().catch((e) => { console.error(e); process.exit(1); });
