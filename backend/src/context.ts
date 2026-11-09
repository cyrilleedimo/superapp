// Dépendances partagées par tous les modules (injection simple, testable).
import type { Config } from './config.js';
import type { Db } from './db.js';
import type { PaymentProvider } from './modules/payments/provider.js';
import type { SmsSender } from './modules/auth/sms.js';
import type { TokenService } from './modules/auth/tokens.js';

export interface Ctx {
  config: Config;
  db: Db;
  sms: SmsSender;
  payments: PaymentProvider;
  tokens: TokenService;
}

export interface AuthUser {
  id: string;
  role: 'user' | 'merchant' | 'driver' | 'admin';
}

declare module 'fastify' {
  interface FastifyRequest {
    user?: AuthUser;
    rawBody?: string;
  }
}
