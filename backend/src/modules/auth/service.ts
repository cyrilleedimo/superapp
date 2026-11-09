// Logique d'identité : inscription par téléphone + OTP, connexion argon2id avec
// verrouillage, rotation des jetons de rafraîchissement avec détection de vol.
import { hash, verify } from '@node-rs/argon2';
import type { Ctx, AuthUser } from '../../context.js';
import { withTx } from '../../db.js';
import { AppError, conflict, unauthorized } from '../../lib/errors.js';
import { otpCode, randomToken, safeEqualHex, sha256Hex } from '../../lib/crypto.js';
import { audit } from '../../lib/audit.js';

const OTP_TTL_MIN = 10;
const OTP_MAX_ATTEMPTS = 5;
const MAX_FAILED_LOGINS = 5;
const LOCK_MINUTES = 15;

// Paramètres argon2id (recommandation OWASP : m=19 Mio, t=2, p=1).
const ARGON = { memoryCost: 19_456, timeCost: 2, parallelism: 1 } as const;
// Hash factice : la connexion d'un numéro inconnu prend le même temps qu'un vrai.
let dummyHash: Promise<string> | undefined;
const getDummyHash = () => (dummyHash ??= hash('dummy-password-for-timing', ARGON));

export interface TokenPair {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

const otpHash = (userId: string, code: string) => sha256Hex(`${userId}:${code}`);

export function makeAuthService(ctx: Ctx) {
  const { db, sms, tokens, config } = ctx;

  async function issueTokens(user: AuthUser, familyId: string | null, userAgent?: string): Promise<TokenPair> {
    const refreshToken = randomToken();
    await db.query(
      `INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at, user_agent)
       VALUES ($1, coalesce($2::uuid, gen_random_uuid()), $3, now() + make_interval(days => $4), $5)`,
      [user.id, familyId, sha256Hex(refreshToken), config.REFRESH_TOKEN_TTL_DAYS, userAgent ?? null],
    );
    return { accessToken: await tokens.sign(user), refreshToken, expiresIn: config.ACCESS_TOKEN_TTL_SEC };
  }

  async function sendOtp(userId: string, phone: string): Promise<void> {
    const code = otpCode();
    await db.query(
      `INSERT INTO otp_codes (user_id, purpose, code_hash, expires_at)
       VALUES ($1, 'verify_phone', $2, now() + make_interval(mins => $3))`,
      [userId, otpHash(userId, code), OTP_TTL_MIN],
    );
    await sms.send(phone, `Votre code de vérification : ${code}. Il expire dans ${OTP_TTL_MIN} min. Ne le partagez jamais.`);
  }

  return {
    async register(input: { phone: string; displayName: string; password: string; email?: string }, ip?: string) {
      const passwordHash = await hash(input.password, ARGON);
      let userId: string;
      try {
        const r = await db.query<{ id: string }>(
          `INSERT INTO users (phone, display_name, password_hash, email) VALUES ($1,$2,$3,$4) RETURNING id`,
          [input.phone, input.displayName, passwordHash, input.email ?? null],
        );
        userId = r.rows[0]!.id;
      } catch (e: unknown) {
        if ((e as { code?: string }).code === '23505') throw conflict('account_exists');
        throw e;
      }
      await sendOtp(userId, input.phone);
      await audit(db, { actorId: userId, action: 'user.register', entity: 'user', entityId: userId, ip });
      return { userId };
    },

    async resendOtp(phone: string) {
      const u = await db.query<{ id: string; status: string }>('SELECT id, status FROM users WHERE phone=$1', [phone]);
      const user = u.rows[0];
      // Réponse identique que le numéro existe ou non (pas d'énumération).
      if (!user || user.status !== 'pending') return;
      const recent = await db.query(
        `SELECT 1 FROM otp_codes WHERE user_id=$1 AND created_at > now() - interval '60 seconds'`, [user.id]);
      if (recent.rowCount) throw new AppError(429, 'otp_too_soon');
      await sendOtp(user.id, phone);
    },

    async verifyPhone(phone: string, code: string, userAgent?: string): Promise<TokenPair> {
      // Les échecs sont RENVOYÉS (pas levés) pour que l'incrément d'essais soit COMMITé.
      const res = await withTx(db, async (tx): Promise<{ id: string; role: AuthUser['role'] } | null> => {
        const u = await tx.query<{ id: string; role: AuthUser['role']; status: string }>(
          'SELECT id, role, status FROM users WHERE phone=$1 FOR UPDATE', [phone]);
        const user = u.rows[0];
        if (!user) return null;
        const o = await tx.query<{ id: string; code_hash: string; attempts: number; expired: boolean }>(
          `SELECT id, code_hash, attempts, expires_at < now() AS expired FROM otp_codes
           WHERE user_id=$1 AND purpose='verify_phone' AND consumed_at IS NULL
           ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, [user.id]);
        const otp = o.rows[0];
        if (!otp || otp.expired || otp.attempts >= OTP_MAX_ATTEMPTS) return null;
        if (!safeEqualHex(otp.code_hash, otpHash(user.id, code))) {
          await tx.query('UPDATE otp_codes SET attempts = attempts + 1 WHERE id=$1', [otp.id]);
          return null;
        }
        await tx.query('UPDATE otp_codes SET consumed_at = now() WHERE id=$1', [otp.id]);
        await tx.query(`UPDATE users SET status='active', updated_at=now() WHERE id=$1 AND status='pending'`, [user.id]);
        return { id: user.id, role: user.role };
      });
      if (!res) throw unauthorized('invalid_code');
      return issueTokens(res, null, userAgent);
    },

    async login(phone: string, password: string, ip?: string, userAgent?: string): Promise<TokenPair> {
      const r = await db.query<{
        id: string; role: AuthUser['role']; status: string; password_hash: string; locked: boolean;
      }>(`SELECT id, role, status, password_hash, coalesce(locked_until > now(), false) AS locked
          FROM users WHERE phone=$1`, [phone]);
      const user = r.rows[0];
      if (!user) {
        await verify(await getDummyHash(), password).catch(() => false);
        throw unauthorized('invalid_credentials');
      }
      if (user.locked) throw new AppError(423, 'account_locked');
      const ok = await verify(user.password_hash, password).catch(() => false);
      if (!ok) {
        await db.query(
          `UPDATE users SET failed_logins = failed_logins + 1,
             locked_until = CASE WHEN failed_logins + 1 >= $2 THEN now() + make_interval(mins => $3) ELSE locked_until END
           WHERE id=$1`, [user.id, MAX_FAILED_LOGINS, LOCK_MINUTES]);
        await audit(db, { actorId: user.id, action: 'auth.login_failed', entity: 'user', entityId: user.id, ip });
        throw unauthorized('invalid_credentials');
      }
      if (user.status === 'pending') throw new AppError(403, 'phone_not_verified');
      if (user.status === 'suspended') throw new AppError(403, 'account_suspended');
      await db.query('UPDATE users SET failed_logins=0, locked_until=NULL WHERE id=$1', [user.id]);
      await audit(db, { actorId: user.id, action: 'auth.login', entity: 'user', entityId: user.id, ip });
      return issueTokens({ id: user.id, role: user.role }, null, userAgent);
    },

    async refresh(token: string, userAgent?: string): Promise<TokenPair> {
      const result = await withTx(db, async (tx) => {
        const r = await tx.query<{
          id: string; user_id: string; family_id: string; revoked: boolean; expired: boolean;
          role: AuthUser['role']; status: string;
        }>(`SELECT t.id, t.user_id, t.family_id, t.revoked_at IS NOT NULL AS revoked,
                   t.expires_at < now() AS expired, u.role, u.status
            FROM refresh_tokens t JOIN users u ON u.id = t.user_id
            WHERE t.token_hash=$1 FOR UPDATE OF t`, [sha256Hex(token)]);
        const row = r.rows[0];
        if (!row) return { error: 'invalid_refresh_token' as const };
        if (row.revoked) {
          // Un jeton déjà utilisé revient : il a probablement été volé. On coupe toute la famille.
          await tx.query('UPDATE refresh_tokens SET revoked_at = now() WHERE family_id=$1 AND revoked_at IS NULL', [row.family_id]);
          await audit(tx, { actorId: row.user_id, action: 'auth.refresh_reuse', entity: 'user', entityId: row.user_id });
          return { error: 'refresh_reuse_detected' as const };
        }
        if (row.expired || row.status !== 'active') return { error: 'invalid_refresh_token' as const };
        await tx.query('UPDATE refresh_tokens SET revoked_at = now() WHERE id=$1', [row.id]);
        return { row };
      });
      // L'erreur est levée APRÈS le COMMIT pour que la révocation de famille persiste.
      if ('error' in result) throw unauthorized(result.error);
      const { row } = result;
      const pair = await issueTokens({ id: row.user_id, role: row.role }, row.family_id, userAgent);
      await db.query(
        `UPDATE refresh_tokens SET replaced_by = (SELECT id FROM refresh_tokens WHERE token_hash=$2) WHERE id=$1`,
        [row.id, sha256Hex(pair.refreshToken)]);
      return pair;
    },

    async logout(token: string): Promise<void> {
      await db.query(
        `UPDATE refresh_tokens SET revoked_at = now()
         WHERE family_id = (SELECT family_id FROM refresh_tokens WHERE token_hash=$1) AND revoked_at IS NULL`,
        [sha256Hex(token)]);
    },
  };
}
