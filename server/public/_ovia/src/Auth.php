<?php
// Identité : inscription par e-mail (obligatoire) + code de vérification, connexion par
// e-mail ou téléphone, verrouillage après échecs, mot de passe oublié, rotation des jetons
// de rafraîchissement avec détection de vol. Les mots de passe ne sont jamais stockés en clair.
declare(strict_types=1);

namespace Ovia;

final class Auth
{
    private const OTP_TTL_MIN = 10;
    private const OTP_MAX_ATTEMPTS = 5;
    private const MAX_FAILED_LOGINS = 5;
    private const LOCK_MINUTES = 15;
    private const REFRESH_DAYS = 30;
    public const PASSWORD_MIN = 8;

    private static function otpHash(string $userId, string $purpose, string $code): string
    {
        return hash_hmac('sha256', "$userId:$purpose:$code", (string) App::$config['data_key']);
    }

    /** @return array{accessToken:string, refreshToken:string, expiresIn:int} */
    private static function issueTokens(string $userId, string $role, ?string $familyId, ?string $ua): array
    {
        $refresh = Util::token();
        App::$db->insert('refresh_tokens', [
            'id' => Util::uuid(), 'user_id' => $userId, 'family_id' => $familyId ?? Util::uuid(),
            'token_hash' => hash('sha256', $refresh), 'expires_at' => Util::now(self::REFRESH_DAYS * 86400),
            'revoked_at' => null, 'replaced_by' => null, 'user_agent' => $ua, 'created_at' => Util::now(),
        ]);
        return ['accessToken' => Jwt::sign((string) App::$config['jwt_secret'], $userId, $role), 'refreshToken' => $refresh, 'expiresIn' => Jwt::TTL];
    }

    /** Crée un code et l'envoie. Renvoie faux si l'e-mail n'a pas pu partir. */
    private static function sendCode(string $userId, string $purpose, string $email): bool
    {
        $code = Util::otp();
        App::$db->insert('otp_codes', [
            'id' => Util::uuid(), 'user_id' => $userId, 'purpose' => $purpose, 'target' => $email,
            'code_hash' => self::otpHash($userId, $purpose, $code), 'attempts' => 0,
            'expires_at' => Util::now(self::OTP_TTL_MIN * 60), 'consumed_at' => null, 'created_at' => Util::now(),
        ]);
        return Mailer::sendCode($email, $code, $purpose);
    }

    private static function tooSoon(string $userId, string $purpose): bool
    {
        return (bool) App::$db->one('SELECT id FROM otp_codes WHERE user_id=? AND purpose=? AND created_at > ?', [$userId, $purpose, Util::now(-60)]);
    }

    /**
     * Vérifie un code. Les échecs sont RENVOYÉS (pas levés) pour que le compteur d'essais soit enregistré.
     * @return array{target:string}|null
     */
    private static function consumeCode(Db $db, string $userId, string $purpose, string $code): ?array
    {
        $otp = $db->one('SELECT id, code_hash, attempts, expires_at, target FROM otp_codes
                         WHERE user_id=? AND purpose=? AND consumed_at IS NULL ORDER BY created_at DESC, id DESC LIMIT 1' . $db->lock(), [$userId, $purpose]);
        if (!$otp || $otp['expires_at'] < Util::now() || (int) $otp['attempts'] >= self::OTP_MAX_ATTEMPTS) return null;
        if (!hash_equals((string) $otp['code_hash'], self::otpHash($userId, $purpose, $code))) {
            $db->run('UPDATE otp_codes SET attempts = attempts + 1 WHERE id=?', [$otp['id']]);
            return null;
        }
        $db->run('UPDATE otp_codes SET consumed_at=? WHERE id=?', [Util::now(), $otp['id']]);
        return ['target' => (string) $otp['target']];
    }

    private static function revokeAll(string $userId): void
    {
        App::$db->run('UPDATE refresh_tokens SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL', [Util::now(), $userId]);
    }

    private static function rawPassword(In $b, string $key): string
    {
        $raw = json_decode(App::$req?->raw ?? '', true);
        $p = is_array($raw) ? ($raw[$key] ?? null) : null;
        if (!is_string($p) || strlen($p) < self::PASSWORD_MIN || strlen($p) > 128) {
            throw AppError::bad('weak_password', self::PASSWORD_MIN . ' caractères minimum');
        }
        return $p;
    }

    /** @param array<string,mixed> $u */
    public static function viewMe(array $u): array
    {
        return [
            'id' => $u['id'], 'email' => $u['email'], 'phone' => $u['phone'], 'displayName' => $u['display_name'],
            'role' => $u['role'], 'status' => $u['status'], 'emailVerified' => (bool) (int) $u['email_verified'],
            'needsEmail' => empty($u['email']) || !(int) $u['email_verified'], 'createdAt' => Util::iso((string) $u['created_at']),
        ];
    }

    public static function routes(): void
    {
        $strict = ['limit' => [10, 60]];
        $db = fn (): Db => App::$db;

        App::route('POST', '/auth/register', function (Req $r) use ($db) {
            $b = $r->body();
            $name = $b->str('displayName', 2, 60);
            $email = $b->email('email');
            $phone = $b->optPhone('phone');
            $hash = Crypto::hashPassword(self::rawPassword($b, 'password'));

            $userId = $db()->tx(function (Db $db) use ($name, $email, $phone, $hash): string {
                $existing = $db->one('SELECT id, status FROM users WHERE email=?' . $db->lock(), [$email]);
                if ($existing && $existing['status'] !== 'pending') throw AppError::conflict('account_exists');
                if ($phone !== null) {
                    $other = $db->one('SELECT id FROM users WHERE phone=?', [$phone]);
                    if ($other && $other['id'] !== ($existing['id'] ?? null)) throw AppError::conflict('phone_exists');
                }
                if ($existing) {
                    // Inscription jamais terminée : la personne recommence, on met à jour au lieu de bloquer.
                    $db->run('UPDATE users SET display_name=?, phone=?, password_hash=?, updated_at=? WHERE id=?', [$name, $phone, $hash, Util::now(), $existing['id']]);
                    return (string) $existing['id'];
                }
                $id = Util::uuid();
                try {
                    $db->insert('users', [
                        'id' => $id, 'email' => $email, 'phone' => $phone, 'display_name' => $name, 'password_hash' => $hash,
                        'status' => 'pending', 'role' => 'user', 'email_verified' => 0, 'failed_logins' => 0, 'locked_until' => null,
                        'created_at' => Util::now(), 'updated_at' => Util::now(),
                    ]);
                } catch (\PDOException $e) {
                    if (Db::isDuplicate($e)) throw AppError::conflict('account_exists');
                    throw $e;
                }
                return $id;
            });
            $sent = self::tooSoon($userId, 'verify_email') ? true : self::sendCode($userId, 'verify_email', $email);
            App::audit($userId, 'user.register', 'user', $userId);
            $r->status = 201;
            return ['userId' => $userId, 'next' => 'verify_email', 'email' => $email, 'emailSent' => $sent];
        }, $strict);

        App::route('POST', '/auth/resend-code', function (Req $r) use ($db) {
            $email = $r->body()->email('email');
            $u = $db()->one('SELECT id, status FROM users WHERE email=?', [$email]);
            $r->status = 202;
            // Réponse identique que le compte existe ou non (pas d'énumération).
            if (!$u || $u['status'] !== 'pending') return ['ok' => true];
            if (self::tooSoon((string) $u['id'], 'verify_email')) throw new AppError(429, 'code_too_soon');
            self::sendCode((string) $u['id'], 'verify_email', $email);
            return ['ok' => true];
        }, $strict);

        App::route('POST', '/auth/verify-email', function (Req $r) use ($db) {
            $b = $r->body();
            $email = $b->email('email');
            $code = $b->str('code', 6, 6);
            $user = $db()->tx(function (Db $db) use ($email, $code): ?array {
                $u = $db->one('SELECT id, role, status FROM users WHERE email=?' . $db->lock(), [$email]);
                if (!$u || !self::consumeCode($db, (string) $u['id'], 'verify_email', $code)) return null;
                $db->run("UPDATE users SET status=CASE WHEN status='pending' THEN 'active' ELSE status END, email_verified=1, updated_at=? WHERE id=?", [Util::now(), $u['id']]);
                // Tout premier compte du serveur (aucun administrateur encore) : il devient l'administrateur.
                if (!$db->one("SELECT id FROM users WHERE role='admin' LIMIT 1")) {
                    $db->run("UPDATE users SET role='admin' WHERE id=?", [$u['id']]);
                    $u['role'] = 'admin';
                }
                return $u;
            });
            if (!$user) throw AppError::unauthorized('invalid_code');
            if ($user['status'] === 'suspended') throw AppError::forbidden('account_suspended');
            return self::issueTokens((string) $user['id'], (string) $user['role'], null, $r->userAgent());
        }, $strict);

        App::route('POST', '/auth/login', function (Req $r) use ($db) {
            $b = $r->body();
            $ident = $b->has('identifier') ? $b->str('identifier', 3, 190) : $b->str('phone', 3, 190);
            $raw = json_decode($r->raw, true);
            $password = is_array($raw) && is_string($raw['password'] ?? null) ? $raw['password'] : '';
            if ($password === '' || strlen($password) > 128) throw AppError::bad('validation_failed', 'password: requis');

            $isEmail = str_contains($ident, '@');
            $key = $isEmail ? mb_strtolower($ident, 'UTF-8') : (preg_replace('/[\s().-]/', '', $ident) ?? '');
            $u = $db()->one('SELECT id, role, status, email, password_hash, locked_until FROM users WHERE ' . ($isEmail ? 'email' : 'phone') . '=?', [$key]);
            if (!$u) {
                // Même durée de réponse qu'un vrai compte : on ne révèle pas quels identifiants existent.
                Crypto::hashPassword($password);
                throw AppError::unauthorized('invalid_credentials');
            }
            if ($u['locked_until'] !== null && $u['locked_until'] > Util::now()) throw new AppError(423, 'account_locked');
            if (!Crypto::verifyPassword($password, (string) $u['password_hash'])) {
                $db()->run('UPDATE users SET failed_logins = failed_logins + 1,
                              locked_until = CASE WHEN failed_logins + 1 >= ? THEN ? ELSE locked_until END WHERE id=?',
                    [self::MAX_FAILED_LOGINS, Util::now(self::LOCK_MINUTES * 60), $u['id']]);
                App::audit((string) $u['id'], 'auth.login_failed', 'user', (string) $u['id']);
                throw AppError::unauthorized('invalid_credentials');
            }
            if ($u['status'] === 'suspended') throw AppError::forbidden('account_suspended');
            if ($u['status'] === 'pending') {
                // Bon mot de passe mais e-mail jamais confirmé : on renvoie un code et l'app ouvre l'écran de vérification.
                if (!self::tooSoon((string) $u['id'], 'verify_email')) self::sendCode((string) $u['id'], 'verify_email', (string) $u['email']);
                throw new AppError(403, 'email_not_verified', (string) $u['email']);
            }
            $sets = 'failed_logins=0, locked_until=NULL';
            $args = [];
            if (Crypto::needsRehash((string) $u['password_hash']) && (defined('PASSWORD_ARGON2ID') || !str_starts_with((string) $u['password_hash'], '$argon2id$'))) {
                $sets .= ', password_hash=?';
                $args[] = Crypto::hashPassword($password);
            }
            $args[] = $u['id'];
            $db()->run("UPDATE users SET $sets WHERE id=?", $args);
            App::audit((string) $u['id'], 'auth.login', 'user', (string) $u['id']);
            return self::issueTokens((string) $u['id'], (string) $u['role'], null, $r->userAgent());
        }, $strict);

        App::route('POST', '/auth/refresh', function (Req $r) use ($db) {
            $token = $r->body()->str('refreshToken', 20, 200);
            $res = $db()->tx(function (Db $db) use ($token): array {
                $row = $db->one('SELECT t.id, t.user_id, t.family_id, t.revoked_at, t.expires_at, u.role, u.status
                                 FROM refresh_tokens t JOIN users u ON u.id = t.user_id WHERE t.token_hash=?' . $db->lock(), [hash('sha256', $token)]);
                if (!$row) return ['error' => 'invalid_refresh_token'];
                if ($row['revoked_at'] !== null) {
                    // Un jeton déjà utilisé revient : il a probablement été volé. On coupe toute la famille.
                    $db->run('UPDATE refresh_tokens SET revoked_at=? WHERE family_id=? AND revoked_at IS NULL', [Util::now(), $row['family_id']]);
                    App::audit((string) $row['user_id'], 'auth.refresh_reuse', 'user', (string) $row['user_id']);
                    return ['error' => 'refresh_reuse_detected'];
                }
                if ($row['expires_at'] < Util::now() || $row['status'] !== 'active') return ['error' => 'invalid_refresh_token'];
                $db->run('UPDATE refresh_tokens SET revoked_at=? WHERE id=?', [Util::now(), $row['id']]);
                return ['row' => $row];
            });
            // L'erreur est levée APRÈS la validation pour que la révocation de famille persiste.
            if (isset($res['error'])) throw AppError::unauthorized($res['error']);
            $row = $res['row'];
            return self::issueTokens((string) $row['user_id'], (string) $row['role'], (string) $row['family_id'], $r->userAgent());
        }, $strict);

        App::route('POST', '/auth/logout', function (Req $r) use ($db) {
            $token = $r->body()->str('refreshToken', 20, 200);
            $row = $db()->one('SELECT family_id FROM refresh_tokens WHERE token_hash=?', [hash('sha256', $token)]);
            if ($row) $db()->run('UPDATE refresh_tokens SET revoked_at=? WHERE family_id=? AND revoked_at IS NULL', [Util::now(), $row['family_id']]);
            return null;
        });

        // ------------------------------------------------- Mot de passe oublié
        App::route('POST', '/auth/forgot-password', function (Req $r) use ($db) {
            $email = $r->body()->email('email');
            $u = $db()->one("SELECT id FROM users WHERE email=? AND status <> 'suspended'", [$email]);
            if ($u && !self::tooSoon((string) $u['id'], 'reset_password')) {
                self::sendCode((string) $u['id'], 'reset_password', $email);
                App::audit((string) $u['id'], 'auth.reset_requested', 'user', (string) $u['id']);
            }
            $r->status = 202;
            return ['ok' => true]; // même réponse que le compte existe ou non
        }, ['limit' => [5, 60]]);

        App::route('POST', '/auth/reset-password', function (Req $r) use ($db) {
            $b = $r->body();
            $email = $b->email('email');
            $code = $b->str('code', 6, 6);
            $hash = Crypto::hashPassword(self::rawPassword($b, 'password'));
            $user = $db()->tx(function (Db $db) use ($email, $code, $hash): ?array {
                $u = $db->one("SELECT id, role FROM users WHERE email=? AND status <> 'suspended'" . $db->lock(), [$email]);
                if (!$u || !self::consumeCode($db, (string) $u['id'], 'reset_password', $code)) return null;
                // Le code reçu par e-mail prouve que l'adresse appartient bien à la personne.
                $db->run("UPDATE users SET password_hash=?, status='active', email_verified=1, failed_logins=0, locked_until=NULL, updated_at=? WHERE id=?",
                    [$hash, Util::now(), $u['id']]);
                $db->run('UPDATE refresh_tokens SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL', [Util::now(), $u['id']]);
                return $u;
            });
            if (!$user) throw AppError::unauthorized('invalid_code');
            App::audit((string) $user['id'], 'auth.password_reset', 'user', (string) $user['id']);
            App::notify((string) $user['id'], 'Mot de passe modifié', 'Ton mot de passe vient d\'être changé. Si ce n\'est pas toi, contacte le support.', null, true);
            return self::issueTokens((string) $user['id'], (string) $user['role'], null, $r->userAgent());
        }, $strict);

        // ------------------------------------------------------ Compte connecté
        App::route('GET', '/me', function (Req $r) use ($db) {
            $u = $db()->one('SELECT * FROM users WHERE id=?', [$r->uid()]);
            if (!$u) throw AppError::notFound();
            return self::viewMe($u);
        }, ['auth' => true]);

        App::route('PATCH', '/me', function (Req $r) use ($db) {
            $b = $r->body();
            $b->only(['displayName', 'phone']);
            $sets = [];
            $args = [];
            if ($b->has('displayName')) { $sets[] = 'display_name=?'; $args[] = $b->str('displayName', 2, 60); }
            if ($b->has('phone')) {
                $phone = $b->phone('phone');
                $other = $db()->one('SELECT id FROM users WHERE phone=? AND id<>?', [$phone, $r->uid()]);
                if ($other) throw AppError::conflict('phone_exists');
                $sets[] = 'phone=?';
                $args[] = $phone;
            }
            if (!$sets) throw AppError::bad('empty_update');
            $args[] = Util::now();
            $args[] = $r->uid();
            $db()->run('UPDATE users SET ' . implode(', ', $sets) . ', updated_at=? WHERE id=?', $args);
            return self::viewMe((array) $db()->one('SELECT * FROM users WHERE id=?', [$r->uid()]));
        }, ['auth' => true]);

        // Ajouter / changer son e-mail (comptes repris de l'ancien serveur, créés par téléphone).
        App::route('POST', '/me/email', function (Req $r) use ($db) {
            $email = $r->body()->email('email');
            $uid = $r->uid();
            if ($db()->one('SELECT id FROM users WHERE email=? AND id<>?', [$email, $uid])) throw AppError::conflict('account_exists');
            if (self::tooSoon($uid, 'change_email')) throw new AppError(429, 'code_too_soon');
            $sent = self::sendCode($uid, 'change_email', $email);
            $r->status = 202;
            return ['ok' => true, 'emailSent' => $sent];
        }, ['auth' => true, 'limit' => [5, 60]]);

        App::route('POST', '/me/email/verify', function (Req $r) use ($db) {
            $code = $r->body()->str('code', 6, 6);
            $uid = $r->uid();
            $ok = $db()->tx(function (Db $db) use ($uid, $code): bool {
                $db->one('SELECT id FROM users WHERE id=?' . $db->lock(), [$uid]);
                $c = self::consumeCode($db, $uid, 'change_email', $code);
                if (!$c) return false;
                if ($db->one('SELECT id FROM users WHERE email=? AND id<>?', [$c['target'], $uid])) throw AppError::conflict('account_exists');
                $db->run('UPDATE users SET email=?, email_verified=1, updated_at=? WHERE id=?', [$c['target'], Util::now(), $uid]);
                return true;
            });
            if (!$ok) throw AppError::unauthorized('invalid_code');
            App::audit($uid, 'user.email_changed', 'user', $uid);
            return self::viewMe((array) $db()->one('SELECT * FROM users WHERE id=?', [$uid]));
        }, ['auth' => true, 'limit' => [10, 60]]);

        App::route('POST', '/me/password', function (Req $r) use ($db) {
            $raw = json_decode($r->raw, true);
            $current = is_array($raw) && is_string($raw['current'] ?? null) ? $raw['current'] : '';
            $new = self::rawPassword($r->body(), 'password');
            $uid = $r->uid();
            $u = $db()->one('SELECT password_hash FROM users WHERE id=?', [$uid]);
            if (!$u || !Crypto::verifyPassword($current, (string) $u['password_hash'])) throw AppError::unauthorized('invalid_credentials');
            $db()->run('UPDATE users SET password_hash=?, updated_at=? WHERE id=?', [Crypto::hashPassword($new), Util::now(), $uid]);
            self::revokeAll($uid);
            App::audit($uid, 'auth.password_changed', 'user', $uid);
            return self::issueTokens($uid, $r->user['role'] ?? 'user', null, $r->userAgent());
        }, ['auth' => true, 'limit' => [5, 60]]);
    }

    /** Vérifie le mot de passe du compte connecté avant une opération sensible (retrait d'argent). */
    public static function requirePassword(Req $r): void
    {
        $raw = json_decode($r->raw, true);
        $p = is_array($raw) && is_string($raw['password'] ?? null) ? $raw['password'] : '';
        $u = App::$db->one('SELECT password_hash FROM users WHERE id=?', [$r->uid()]);
        if ($p === '' || !$u || !Crypto::verifyPassword($p, (string) $u['password_hash'])) throw AppError::forbidden('password_required');
    }
}
