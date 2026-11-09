// Monte une API complète sur une vraie base PostgreSQL de test, remise à zéro.
import type { FastifyInstance } from 'fastify';
import { loadConfig } from '../src/config.js';
import { createPool } from '../src/db.js';
import { migrate } from '../src/migrate.js';
import { buildApp } from '../src/app.js';
import type { Ctx } from '../src/context.js';
import { MemorySmsSender } from '../src/modules/auth/sms.js';
import { makeTokenService } from '../src/modules/auth/tokens.js';
import { SandboxProvider } from '../src/modules/payments/provider.js';

export interface TestEnv { app: FastifyInstance; ctx: Ctx; sms: MemorySmsSender; psp: SandboxProvider }

export async function setup(): Promise<TestEnv> {
  const config = loadConfig({
    NODE_ENV: 'test',
    DATABASE_URL: process.env.TEST_DATABASE_URL ?? 'postgres://postgres@localhost:5433/superapp_test',
    JWT_SECRET: 'test-secret-0123456789abcdef0123456789abcdef0123',
    BUYER_FEE_BPS: '1000',        // valeur de TEST uniquement
    BUYER_FEE_FIXED_XAF: '0',
    PAYMENT_PROVIDER: 'sandbox',
    SANDBOX_WEBHOOK_SECRET: 'whsec_test',
    UPLOAD_DIR: process.env.TEST_UPLOAD_DIR ?? './test-uploads',
    RIDE_BASE_XAF: '500',         // valeurs de TEST uniquement
    RIDE_PER_KM_XAF: '200',
    AUTO_RELEASE_DAYS: '7',
  });
  const db = createPool(config.DATABASE_URL);
  await db.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await migrate(db);
  const sms = new MemorySmsSender();
  const psp = new SandboxProvider(config.SANDBOX_WEBHOOK_SECRET);
  const ctx: Ctx = { config, db, sms, payments: psp, tokens: makeTokenService(config.JWT_SECRET, 900) };
  const app = await buildApp(ctx);
  return { app, ctx, sms, psp };
}

export async function teardown(env: TestEnv) {
  await env.app.close();
  await env.ctx.db.end();
}

let ipSeq = 1;
/** Chaque appel simule un client distinct (évite le rate limit entre tests). */
export const freshIp = () => `10.0.${Math.floor(ipSeq / 250)}.${(ipSeq++ % 250) + 1}`;

/** Crée un compte vérifié et renvoie ses jetons. */
export async function signup(env: TestEnv, phone: string, name = 'Utilisateur Test') {
  const ip = freshIp();
  const r1 = await env.app.inject({ method: 'POST', url: '/auth/register', remoteAddress: ip,
    payload: { phone, password: 'motdepasse-solide-42', displayName: name } });
  if (r1.statusCode !== 201) throw new Error(`register ${r1.statusCode} ${r1.body}`);
  const code = env.sms.lastCodeFor(phone)!;
  const r2 = await env.app.inject({ method: 'POST', url: '/auth/verify-phone', remoteAddress: ip, payload: { phone, code } });
  if (r2.statusCode !== 200) throw new Error(`verify ${r2.statusCode} ${r2.body}`);
  const tokens = r2.json() as { accessToken: string; refreshToken: string };
  const me = (await env.app.inject({ method: 'GET', url: '/me', headers: { authorization: `Bearer ${tokens.accessToken}` } })).json();
  return { ...tokens, id: me.id as string, auth: { authorization: `Bearer ${tokens.accessToken}` } };
}
