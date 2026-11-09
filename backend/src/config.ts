// Configuration typée, validée au démarrage : l'app refuse de démarrer si une
// variable manque ou est dangereuse (ex. fournisseur « sandbox » en production).
import { z } from 'zod';

const schema = z
  .object({
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    PORT: z.coerce.number().int().default(8080),
    DATABASE_URL: z.string().min(1),
    // Secret HMAC des jetons d'accès : 32 octets minimum (base64 ou hex).
    JWT_SECRET: z.string().min(43, 'JWT_SECRET doit faire au moins 32 octets'),
    ACCESS_TOKEN_TTL_SEC: z.coerce.number().int().positive().default(900),
    REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(30),
    CORS_ORIGINS: z.string().default(''),
    // Nombre de proxys de confiance devant l'API (0 = aucun). Évite l'usurpation d'IP via X-Forwarded-For.
    TRUST_PROXY_HOPS: z.coerce.number().int().min(0).max(5).default(0),
    // Frais de protection acheteur, en points de base (100 = 1 %) + part fixe.
    // DÉCISION COMMERCIALE : à fixer par l'entreprise. Aucune valeur par défaut.
    BUYER_FEE_BPS: z.coerce.number().int().min(0).max(5000),
    BUYER_FEE_FIXED_XAF: z.coerce.number().int().min(0).default(0),
    PAYMENT_PROVIDER: z.enum(['sandbox', 'notchpay']).default('sandbox'),
    NOTCHPAY_API_KEY: z.string().optional(),
    NOTCHPAY_WEBHOOK_HASH: z.string().optional(),
    PAYMENT_CALLBACK_URL: z.string().url().default('http://localhost:8080/payments/return'),
    SANDBOX_WEBHOOK_SECRET: z.string().default('sandbox-secret-dev-only'),
    // URL publique de l'API (liens des médias) et dossier de stockage local des images.
    // Production : remplacer le stockage disque par [OBJECT STORAGE] (S3 compatible).
    PUBLIC_BASE_URL: z.string().url().default('http://localhost:8080'),
    UPLOAD_DIR: z.string().default('./uploads'),
    // Commandes impayées annulées après N minutes (l'article redevient disponible).
    PENDING_ORDER_TTL_MIN: z.coerce.number().int().min(5).default(30),
    // Libération automatique du séquestre N jours après paiement. DÉCISION COMMERCIALE : vide = désactivé.
    AUTO_RELEASE_DAYS: z.coerce.number().int().min(1).optional(),
    // Tarification VTC. DÉCISION COMMERCIALE : vide = service VTC désactivé (503).
    RIDE_BASE_XAF: z.coerce.number().int().min(0).optional(),
    RIDE_PER_KM_XAF: z.coerce.number().int().min(1).optional(),
    RIDE_DISPATCH_RADIUS_KM: z.coerce.number().min(0.5).max(50).default(5),
    PAYOUT_MIN_XAF: z.coerce.number().int().min(1).default(1),
    DISABLE_JOBS: z.enum(['true', 'false']).default('false'),
    // Dossier du miroir lisible « un fichier par utilisateur » (vide = désactivé).
    EXPORT_DIR: z.string().optional(),
  })
  .superRefine((c, ctx) => {
    if (c.NODE_ENV === 'production' && c.PAYMENT_PROVIDER === 'sandbox') {
      ctx.addIssue({ code: 'custom', message: 'PAYMENT_PROVIDER=sandbox interdit en production' });
    }
    if (c.PAYMENT_PROVIDER === 'notchpay' && (!c.NOTCHPAY_API_KEY || !c.NOTCHPAY_WEBHOOK_HASH)) {
      ctx.addIssue({ code: 'custom', message: 'NOTCHPAY_API_KEY et NOTCHPAY_WEBHOOK_HASH requis' });
    }
  });

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const msg = parsed.error.issues.map((i) => `${i.path.join('.') || 'config'}: ${i.message}`).join('\n');
    throw new Error(`Configuration invalide :\n${msg}`);
  }
  return parsed.data;
}
