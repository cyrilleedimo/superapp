// Envoi de SMS (codes OTP). Le fournisseur réel est un choix commercial :
// [SMS PROVIDER] à brancher ici en implémentant SmsSender.

export interface SmsSender {
  send(phone: string, text: string): Promise<void>;
}

/**
 * Développement/tests uniquement : garde les messages en mémoire.
 * Refusé en production (voir buildContext dans server.ts).
 */
export class MemorySmsSender implements SmsSender {
  readonly outbox: { phone: string; text: string }[] = [];
  async send(phone: string, text: string): Promise<void> {
    this.outbox.push({ phone, text });
  }
  lastCodeFor(phone: string): string | undefined {
    const m = [...this.outbox].reverse().find((x) => x.phone === phone);
    return m?.text.match(/\b(\d{6})\b/)?.[1];
  }
}
