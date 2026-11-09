// Abstraction prestataire de paiement : on peut brancher [PAYMENT PROVIDERS]
// (Notch Pay, CinetPay, Flutterwave, opérateurs directs…) sans toucher au métier.
import { hmacSha256Hex, randomToken, safeEqualHex } from '../../lib/crypto.js';

export type ProviderStatus = 'pending' | 'succeeded' | 'failed';

export interface InitInput {
  ourReference: string;
  amountXaf: number;
  description: string;
  customer: { name: string; phone: string; email?: string | null };
  callbackUrl: string;
}
export interface InitResult { providerReference: string; checkoutUrl: string }
export interface RetrieveResult {
  providerReference: string;
  status: ProviderStatus;
  amountXaf: number;
  currency: string;
  raw: unknown;
}

export interface PaymentProvider {
  readonly name: string;
  /** Crée la session de paiement hébergée (le client y saisit carte / Mobile Money). */
  initialize(input: InitInput): Promise<InitResult>;
  /** Source de vérité : interroge le prestataire, serveur à serveur. */
  retrieve(providerReference: string): Promise<RetrieveResult>;
  /** Vérifie la signature du webhook sur le corps BRUT. */
  verifyWebhook(rawBody: string, headers: Record<string, string | string[] | undefined>): boolean;
  /** Références candidates présentes dans le webhook (utilisées seulement pour retrouver le paiement). */
  referencesFromWebhook(body: unknown): string[];
}

const header = (h: Record<string, string | string[] | undefined>, k: string) => {
  const v = h[k];
  return Array.isArray(v) ? v[0] : v;
};

function collectRefs(body: unknown): string[] {
  const out = new Set<string>();
  const visit = (o: unknown, depth: number) => {
    if (!o || typeof o !== 'object' || depth > 3) return;
    for (const [k, v] of Object.entries(o as Record<string, unknown>)) {
      if (typeof v === 'string' && /reference|trxref/i.test(k) && v.length <= 120) out.add(v);
      else if (typeof v === 'object') visit(v, depth + 1);
    }
  };
  visit(body, 0);
  return [...out];
}

// ------------------------------------------------------------------ Notch Pay
// Doc : https://developer.notchpay.co — POST /payments, GET /payments/{reference},
// webhook signé HMAC-SHA256 (hex) du corps brut, en-tête x-notch-signature.
export class NotchPayProvider implements PaymentProvider {
  readonly name = 'notchpay';
  private readonly base = 'https://api.notchpay.co';
  constructor(private readonly apiKey: string, private readonly webhookHash: string) {}

  private async call(path: string, init: RequestInit = {}): Promise<Record<string, unknown>> {
    const res = await fetch(this.base + path, {
      ...init,
      headers: { Authorization: this.apiKey, 'Content-Type': 'application/json', Accept: 'application/json' },
      signal: AbortSignal.timeout(15_000),
    });
    const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;
    if (!res.ok) throw new Error(`notchpay ${path} -> HTTP ${res.status}: ${String(json.message ?? '')}`);
    return json;
  }

  async initialize(i: InitInput): Promise<InitResult> {
    const json = await this.call('/payments', {
      method: 'POST',
      body: JSON.stringify({
        amount: i.amountXaf,
        currency: 'XAF',
        reference: i.ourReference,
        description: i.description,
        callback: i.callbackUrl,
        customer: { name: i.customer.name, phone: i.customer.phone, email: i.customer.email ?? undefined },
      }),
    });
    const trx = json.transaction as { reference?: string } | undefined;
    const url = json.authorization_url;
    if (!trx?.reference || typeof url !== 'string') throw new Error('notchpay: réponse d\'initialisation inattendue');
    return { providerReference: trx.reference, checkoutUrl: url };
  }

  async retrieve(ref: string): Promise<RetrieveResult> {
    const json = await this.call(`/payments/${encodeURIComponent(ref)}`);
    const t = (json.transaction ?? {}) as { reference?: string; status?: string; amount?: number; currency?: string };
    const s = (t.status ?? '').toLowerCase();
    const status: ProviderStatus = s === 'complete' ? 'succeeded'
      : ['failed', 'canceled', 'cancelled', 'expired', 'rejected'].includes(s) ? 'failed' : 'pending';
    return { providerReference: t.reference ?? ref, status, amountXaf: Number(t.amount ?? 0), currency: String(t.currency ?? ''), raw: json };
  }

  verifyWebhook(raw: string, h: Record<string, string | string[] | undefined>): boolean {
    const sig = header(h, 'x-notch-signature');
    return !!sig && safeEqualHex(sig, hmacSha256Hex(this.webhookHash, raw));
  }

  referencesFromWebhook(body: unknown): string[] { return collectRefs(body); }
}

// -------------------------------------------------------------------- Sandbox
// Faux prestataire pour développement et tests automatisés. Interdit en production.
export class SandboxProvider implements PaymentProvider {
  readonly name = 'sandbox';
  private readonly store = new Map<string, { status: ProviderStatus; amountXaf: number; currency: string }>();
  constructor(private readonly secret: string) {}

  async initialize(i: InitInput): Promise<InitResult> {
    const ref = `sbx_${randomToken(12)}`;
    this.store.set(ref, { status: 'pending', amountXaf: i.amountXaf, currency: 'XAF' });
    return { providerReference: ref, checkoutUrl: `https://sandbox.invalid/checkout/${ref}` };
  }
  async retrieve(ref: string): Promise<RetrieveResult> {
    const s = this.store.get(ref);
    if (!s) throw new Error('sandbox: référence inconnue');
    return { providerReference: ref, ...s, raw: { sandbox: true, ...s } };
  }
  verifyWebhook(raw: string, h: Record<string, string | string[] | undefined>): boolean {
    const sig = header(h, 'x-sandbox-signature');
    return !!sig && safeEqualHex(sig, hmacSha256Hex(this.secret, raw));
  }
  referencesFromWebhook(body: unknown): string[] { return collectRefs(body); }

  // --- outils de test ---
  simulate(ref: string, status: ProviderStatus, amountXaf?: number) {
    const s = this.store.get(ref);
    if (!s) throw new Error('sandbox: référence inconnue');
    this.store.set(ref, { ...s, status, amountXaf: amountXaf ?? s.amountXaf });
  }
  sign(raw: string) { return hmacSha256Hex(this.secret, raw); }
}
