// Erreur métier : un code stable que l'app cliente peut traduire, et un statut HTTP.
import type { ZodType } from 'zod';

export class AppError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message?: string,
  ) {
    super(message ?? code);
  }
}

export const badRequest = (code: string, msg?: string) => new AppError(400, code, msg);
export const unauthorized = (code = 'unauthorized') => new AppError(401, code);
export const forbidden = (code = 'forbidden') => new AppError(403, code);
export const notFound = (code = 'not_found') => new AppError(404, code);
export const conflict = (code: string, msg?: string) => new AppError(409, code, msg);

/** Valide une entrée avec Zod ; lève une 400 lisible sinon. */
export function parse<T>(schema: ZodType<T>, data: unknown): T {
  const r = schema.safeParse(data);
  if (!r.success) {
    const detail = r.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ');
    throw badRequest('validation_failed', detail);
  }
  return r.data;
}
