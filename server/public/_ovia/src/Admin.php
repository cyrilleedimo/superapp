<?php
// Administration : tableau de bord, utilisateurs, réglages (paiement, e-mail, IA, tarifs),
// bascule vers MySQL, journal des e-mails. Réservé au rôle admin.
declare(strict_types=1);

namespace Ovia;

final class Admin
{
    private const DAYS = 14;

    public static function routes(): void
    {
        $admin = ['auth' => ['admin']];
        $db = fn (): Db => App::$db;

        // Totaux + évolution sur 14 jours (un point par jour, même sans activité).
        App::route('GET', '/admin/metrics', function () use ($db) {
            $start = gmdate('Y-m-d', time() - (self::DAYS - 1) * 86400);
            $series = function (string $table, bool $revenue = false) use ($db, $start): array {
                $days = [];
                for ($i = 0; $i < self::DAYS; $i++) {
                    $d = gmdate('Y-m-d', strtotime($start . ' UTC') + $i * 86400);
                    $days[$d] = ['day' => $d, 'count' => 0] + ($revenue ? ['revenueXaf' => 0] : []);
                }
                $cols = $revenue ? 'created_at, total_xaf, status' : 'created_at';
                foreach ($db()->all("SELECT $cols FROM $table WHERE created_at >= ?", ["$start 00:00:00"]) as $row) {
                    $d = substr((string) $row['created_at'], 0, 10);
                    if (!isset($days[$d])) continue;
                    $days[$d]['count']++;
                    if ($revenue && !in_array($row['status'], ['cancelled', 'pending_payment'], true)) $days[$d]['revenueXaf'] += (int) $row['total_xaf'];
                }
                return array_values($days);
            };
            return [
                'days' => ['users' => $series('users'), 'listings' => $series('listings'), 'orders' => $series('orders', true)],
                'totals' => [
                    'usersTotal' => (int) $db()->val('SELECT count(*) FROM users'),
                    'listingsActive' => (int) $db()->val("SELECT count(*) FROM listings WHERE status='active'"),
                    'ordersTotal' => (int) $db()->val('SELECT count(*) FROM orders'),
                    'revenueTotalXaf' => (int) $db()->val("SELECT coalesce(sum(total_xaf),0) FROM orders WHERE status NOT IN ('cancelled','pending_payment')"),
                    'payoutsPending' => (int) $db()->val("SELECT count(*) FROM payouts WHERE status='requested'"),
                    'payoutsPendingXaf' => (int) $db()->val("SELECT coalesce(sum(amount_xaf),0) FROM payouts WHERE status='requested'"),
                ],
            ];
        }, $admin);

        App::route('GET', '/admin/users', function (Req $r) use ($db) {
            $q = $r->query()->optStr('q', 1, 100);
            $where = '';
            $args = [];
            if ($q !== null) {
                $like = '%' . str_replace(['!', '%', '_'], ['!!', '!%', '!_'], mb_strtolower($q)) . '%';
                $where = "WHERE lower(display_name) LIKE ? ESCAPE '!' OR lower(coalesce(email,'')) LIKE ? ESCAPE '!' OR coalesce(phone,'') LIKE ? ESCAPE '!'";
                $args = [$like, $like, $like];
            }
            $rows = $db()->all("SELECT id, display_name, email, phone, role, status, email_verified, created_at FROM users $where ORDER BY created_at DESC LIMIT 200", $args);
            return ['items' => array_map(fn ($u) => ['id' => $u['id'], 'displayName' => $u['display_name'], 'email' => $u['email'], 'phone' => $u['phone'],
                                                     'role' => $u['role'], 'status' => $u['status'], 'emailVerified' => (bool) (int) $u['email_verified'],
                                                     'createdAt' => Util::iso((string) $u['created_at'])], $rows)];
        }, $admin);

        App::route('POST', '/admin/users/{id}', function (Req $r) use ($db) {
            $b = $r->body();
            $b->only(['status', 'role']);
            if ($r->id() === $r->uid()) throw AppError::forbidden('cannot_edit_yourself'); // un admin ne se retire pas ses propres droits par erreur
            if (!$db()->one('SELECT id FROM users WHERE id=?', [$r->id()])) throw AppError::notFound();
            if ($b->has('status')) {
                $status = $b->enum('status', ['active', 'suspended']);
                $db()->run('UPDATE users SET status=?, updated_at=? WHERE id=?', [$status, Util::now(), $r->id()]);
                if ($status === 'suspended') $db()->run('UPDATE refresh_tokens SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL', [Util::now(), $r->id()]);
                App::audit($r->uid(), "user.$status", 'user', $r->id());
            }
            if ($b->has('role')) {
                $role = $b->enum('role', ['user', 'merchant', 'driver', 'admin']);
                $db()->run('UPDATE users SET role=?, updated_at=? WHERE id=?', [$role, Util::now(), $r->id()]);
                App::audit($r->uid(), 'user.role', 'user', $r->id(), ['role' => $role]);
            }
            return ['ok' => true];
        }, $admin);

        // ------------------------------------------------------------ Réglages
        App::route('GET', '/admin/settings', function () {
            $out = [];
            foreach (Settings::DEFS as $k => [$type, $default, $secret]) {
                if ($secret) {
                    $v = App::$settings->str($k);
                    $out[$k] = ['type' => $type, 'secret' => true, 'isSet' => $v !== '', 'hint' => $v === '' ? '' : substr($v, 0, 8) . '…'];
                } else {
                    $out[$k] = ['type' => $type, 'secret' => false,
                                'value' => match ($type) { 'int' => App::$settings->int($k), 'bool' => App::$settings->bool($k), default => App::$settings->str($k) }];
                }
            }
            return ['settings' => $out];
        }, $admin);

        App::route('PATCH', '/admin/settings', function (Req $r) {
            $raw = json_decode($r->raw, true);
            if (!is_array($raw) || !$raw) throw AppError::bad('empty_update');
            foreach ($raw as $k => $v) {
                $def = Settings::DEFS[$k] ?? null;
                if (!$def) throw AppError::bad('validation_failed', "$k: réglage inconnu");
                $value = match ($def[0]) {
                    'int' => is_int($v) && $v >= 0 && $v <= 100000000 ? (string) $v : throw AppError::bad('validation_failed', "$k: nombre attendu"),
                    'bool' => is_bool($v) ? ($v ? '1' : '0') : throw AppError::bad('validation_failed', "$k: vrai ou faux attendu"),
                    default => is_string($v) && strlen($v) <= 500 ? trim($v) : throw AppError::bad('validation_failed', "$k: texte attendu"),
                };
                if ($k === 'fees.buyer_bps' && (int) $value > 5000) throw AppError::bad('validation_failed', "$k: 5000 maximum (50 %)");
                if ($k === 'payments.provider' && !in_array($value, ['none', 'notchpay', 'sandbox'], true)) throw AppError::bad('validation_failed', "$k");
                if ($k === 'smtp.secure' && !in_array($value, ['ssl', 'tls', 'none'], true)) throw AppError::bad('validation_failed', "$k");
                if ($k === 'notchpay.public_key' && $value !== '' && str_starts_with($value, 'sk')) {
                    throw AppError::bad('wrong_key_type', 'Notch Pay attend ici la clé PUBLIQUE (elle commence par pk), pas la clé secrète.');
                }
                if ($k === 'app.public_url' && $value !== '' && !preg_match('#^https://[A-Za-z0-9.-]+(:\d+)?$#', $value)) throw AppError::bad('validation_failed', "$k: adresse https attendue");
                App::$settings->set($k, $value);
                App::audit($r->uid(), 'settings.update', 'setting', $k);
            }
            return ['ok' => true];
        }, $admin);

        // État technique du serveur (ce qu'il faut savoir sans ouvrir de fichier).
        App::route('GET', '/admin/system', function () use ($db) {
            return [
                'storage' => $db()->driver === 'mysql' ? 'mysql' : 'file',
                'storageLabel' => $db()->driver === 'mysql' ? 'Base MySQL' : 'Fichier privé (aucune base nécessaire)',
                'php' => PHP_VERSION,
                'extensions' => ['gd' => extension_loaded('gd'), 'sodium' => extension_loaded('sodium'), 'curl' => extension_loaded('curl'),
                                 'pdo_mysql' => extension_loaded('pdo_mysql'), 'pdo_sqlite' => extension_loaded('pdo_sqlite'), 'argon2' => defined('PASSWORD_ARGON2ID')],
                'mailMode' => App::$settings->str('smtp.host') !== '' ? 'smtp' : 'mail()',
                'mailFrom' => Mailer::fromAddress(),
                'paymentsReady' => Payments::provider() !== null,
                'webhookUrl' => App::publicUrl() . '/api/webhooks/payments',
                'publicUrl' => App::publicUrl(),
                'demo' => Demo::status(),
            ];
        }, $admin);

        // Annonces d'exemple : les remettre ou les retirer à la main.
        App::route('POST', '/admin/demo', function (Req $r) {
            $action = $r->body()->enum('action', ['install', 'remove']);
            if ($action === 'install') {
                App::$settings->set('demo.enabled', '1');
                App::$settings->set('demo.state', 'installing', false);
                Demo::install(100);
            } else {
                Demo::remove();
            }
            App::audit($r->uid(), "demo.$action", 'system');
            return Demo::status();
        }, $admin + ['limit' => [6, 60]]);

        // Bascule vers MySQL : on vérifie la connexion, on enregistre, et la requête suivante recopie le fichier.
        App::route('POST', '/admin/database', function (Req $r) {
            $b = $r->body();
            $raw = json_decode($r->raw, true) ?: [];
            $cfg = ['host' => $b->str('host', 1, 190, 'localhost'), 'port' => $b->int('port', 1, 65535, 3306), 'name' => $b->str('name', 1, 64),
                    'user' => $b->str('user', 1, 64), 'pass' => is_string($raw['pass'] ?? null) ? $raw['pass'] : ''];
            if (!extension_loaded('pdo_mysql')) throw new AppError(503, 'mysql_unavailable', 'extension PHP pdo_mysql absente');
            try {
                Db::mysql($cfg)->val('SELECT 1');
            } catch (\Throwable $e) {
                throw AppError::bad('database_unreachable', Util::clip($e->getMessage(), 200));
            }
            App::writeConfig(['mysql' => $cfg] + App::$config);
            App::audit($r->uid(), 'database.configured', 'system');
            return ['ok' => true];
        }, $admin + ['limit' => [5, 60]]);

        // ---------------------------------------------------------- E-mails
        App::route('GET', '/admin/mail-log', function () use ($db) {
            $rows = $db()->all('SELECT to_email, subject, code, status, error, created_at FROM mail_outbox ORDER BY id DESC LIMIT 40');
            return ['items' => array_map(fn ($m) => ['email' => $m['to_email'], 'subject' => $m['subject'], 'code' => $m['code'], 'status' => $m['status'],
                                                     'error' => $m['error'], 'createdAt' => Util::iso((string) $m['created_at'])], $rows)];
        }, $admin);

        App::route('POST', '/admin/mail-test', function (Req $r) {
            $to = $r->body()->email('to');
            $ok = Mailer::send($to, 'Test d\'envoi ' . App::$settings->str('app.name'), "Si tu lis ce message, l'envoi d'e-mails fonctionne.",
                '<p>Si tu lis ce message, l\'envoi d\'e-mails fonctionne. ✅</p>', null);
            $last = App::$db->one('SELECT error FROM mail_outbox ORDER BY id DESC LIMIT 1');
            return ['sent' => $ok, 'error' => $ok ? null : ($last['error'] ?? 'inconnue'), 'from' => Mailer::fromAddress()];
        }, $admin + ['limit' => [5, 60]]);
    }
}

/** Tâches de fond : au plus une fois par minute, déclenchées par le trafic (ou par cron.php). */
final class Jobs
{
    public static function maybeRun(bool $force = false): void
    {
        Mailer::flush();
        $last = (int) (App::$settings->raw('jobs.last_run') ?? 0);
        if (!$force && time() - $last < 60) return;
        App::$settings->set('jobs.last_run', (string) time(), false);
        try { Demo::tick(); } catch (\Throwable $e) { error_log('Ovia exemples : ' . $e->getMessage()); }
        $expired = Orders::expirePending();
        $released = Orders::autoRelease();
        // Ménage : codes et compteurs périmés, vieux journaux d'e-mails.
        App::$db->run('DELETE FROM otp_codes WHERE created_at < ?', [Util::now(-2 * 86400)]);
        App::$db->run('DELETE FROM rate_limits WHERE window_start < ?', [time() - 3600]);
        App::$db->run('DELETE FROM mail_outbox WHERE created_at < ?', [Util::now(-14 * 86400)]);
        App::$db->run('DELETE FROM refresh_tokens WHERE expires_at < ?', [Util::now(-7 * 86400)]);
        Mailer::flush();
        if ($expired || $released) error_log("Ovia jobs : $expired commande(s) expirée(s), $released séquestre(s) libéré(s)");
    }
}
