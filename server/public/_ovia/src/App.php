<?php
// Cœur de l'API : configuration auto-générée, ouverture des données (fichier ou MySQL),
// routeur, authentification par jeton, limitation de débit, réglages, notifications.
declare(strict_types=1);

namespace Ovia;

/** Requête en cours. */
final class Req
{
    public string $method;
    public string $path;
    public string $raw;
    public string $ip;
    /** @var array<string,string> */
    public array $params = [];
    /** @var array{id:string, role:string}|null */
    public ?array $user = null;
    public int $status = 200;
    private ?In $body = null;

    public function __construct()
    {
        $this->method = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
        $uri = (string) parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
        $pos = strpos($uri, '/api/');
        $path = $pos === false ? (str_ends_with($uri, '/api') ? '/' : $uri) : substr($uri, $pos + 4);
        if (str_starts_with($path, '/index.php')) $path = substr($path, 10) ?: '/';
        $this->path = '/' . trim(rawurldecode($path), '/');
        $this->raw = (string) file_get_contents('php://input');
        $this->ip = (string) ($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0');
    }

    public function header(string $name): ?string
    {
        $key = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
        $v = $_SERVER[$key] ?? $_SERVER['REDIRECT_' . $key] ?? null;
        if ($v === null && $name === 'Content-Type') $v = $_SERVER['CONTENT_TYPE'] ?? null;
        if ($v === null && function_exists('getallheaders')) {
            foreach (getallheaders() as $k => $val) {
                if (strcasecmp((string) $k, $name) === 0) return (string) $val;
            }
        }
        return $v === null ? null : (string) $v;
    }

    /** Corps JSON validé (objet). */
    public function body(): In
    {
        if ($this->body) return $this->body;
        if (strlen($this->raw) > 262144) throw new AppError(413, 'body_too_large');
        if ($this->raw === '') return $this->body = new In([]);
        $j = json_decode($this->raw, true);
        if (!is_array($j)) throw AppError::bad('invalid_json');
        return $this->body = new In($j);
    }

    public function query(): In
    {
        return new In(array_filter($_GET, 'is_string'));
    }

    public function id(string $name = 'id'): string
    {
        $v = $this->params[$name] ?? '';
        if (!preg_match(In::UUID, $v)) throw AppError::bad('validation_failed', "$name: identifiant invalide");
        return $v;
    }

    /** Identifiant de l'utilisateur connecté (la route doit exiger l'authentification). */
    public function uid(): string
    {
        if (!$this->user) throw AppError::unauthorized();
        return $this->user['id'];
    }

    public function userAgent(): ?string
    {
        $ua = $this->header('User-Agent');
        return $ua === null ? null : substr($ua, 0, 200);
    }

    public function idempotencyKey(): string
    {
        $k = $this->header('Idempotency-Key') ?? '';
        if (!preg_match('/^[A-Za-z0-9_-]{16,64}$/', $k)) throw AppError::bad('idempotency_key_required');
        return $k;
    }
}

/** Réglages modifiables depuis l'application (Admin → Réglages). Les secrets sont chiffrés en base. */
final class Settings
{
    /** @var array<string, array{v:string, secret:int}>|null */
    private ?array $rows = null;

    /** Réglages connus : type, valeur par défaut, secret ou non. */
    public const DEFS = [
        'app.name' => ['string', 'Ovia', false],
        'app.public_url' => ['string', '', false],
        'pilot.show_codes' => ['bool', true, false],
        'fees.buyer_bps' => ['int', 500, false],
        'fees.buyer_fixed_xaf' => ['int', 0, false],
        'payments.provider' => ['string', 'none', false],
        'payments.cash_enabled' => ['bool', true, false],
        'notchpay.public_key' => ['string', '', true],
        'notchpay.webhook_hash' => ['string', '', true],
        'mail.from' => ['string', '', false],
        'mail.from_name' => ['string', 'Ovia', false],
        'smtp.host' => ['string', '', false],
        'smtp.port' => ['int', 465, false],
        'smtp.user' => ['string', '', false],
        'smtp.pass' => ['string', '', true],
        'smtp.secure' => ['string', 'ssl', false],
        'gemini.api_key' => ['string', '', true],
        'gemini.model' => ['string', 'gemini-2.5-flash', false],
        'rides.base_xaf' => ['int', 0, false],
        'rides.per_km_xaf' => ['int', 0, false],
        'rides.radius_km' => ['int', 5, false],
        'orders.pending_ttl_min' => ['int', 30, false],
        'orders.auto_release_days' => ['int', 0, false],
        'payout.min_xaf' => ['int', 500, false],
    ];

    public function __construct(private Db $db, private string $key) {}

    private function load(): void
    {
        if ($this->rows !== null) return;
        $this->rows = [];
        foreach ($this->db->all('SELECT k, v, secret FROM settings') as $r) {
            $this->rows[(string) $r['k']] = ['v' => (string) $r['v'], 'secret' => (int) $r['secret']];
        }
    }

    public function raw(string $k): ?string
    {
        $this->load();
        $row = $this->rows[$k] ?? null;
        if ($row === null) return null;
        return $row['secret'] ? Crypto::open($row['v'], $this->key) : $row['v'];
    }

    public function str(string $k): string
    {
        return $this->raw($k) ?? (string) (self::DEFS[$k][1] ?? '');
    }

    public function int(string $k): int
    {
        $v = $this->raw($k);
        return $v === null ? (int) (self::DEFS[$k][1] ?? 0) : (int) $v;
    }

    public function bool(string $k): bool
    {
        $v = $this->raw($k);
        return $v === null ? (bool) (self::DEFS[$k][1] ?? false) : $v === '1';
    }

    public function set(string $k, string $value, ?bool $secret = null): void
    {
        $secret ??= (bool) (self::DEFS[$k][2] ?? false);
        $stored = $secret ? Crypto::seal($value, $this->key) : $value;
        if ($this->db->run('UPDATE settings SET v=?, secret=?, updated_at=? WHERE k=?', [$stored, $secret ? 1 : 0, Util::now(), $k]) === 0) {
            if (!$this->db->insertIgnore('settings', ['k' => $k, 'v' => $stored, 'secret' => $secret ? 1 : 0, 'updated_at' => Util::now()])) {
                $this->db->run('UPDATE settings SET v=?, secret=?, updated_at=? WHERE k=?', [$stored, $secret ? 1 : 0, Util::now(), $k]);
            }
        }
        $this->rows[$k] = ['v' => $stored, 'secret' => $secret ? 1 : 0];
    }
}

/** Jetons d'accès JWT courts (15 min) signés HS256, vérification stricte. */
final class Jwt
{
    private const ISS = 'ovia-api';
    private const AUD = 'ovia-client';
    public const TTL = 900;

    public static function sign(string $secret, string $userId, string $role): string
    {
        $h = Util::b64u('{"alg":"HS256","typ":"JWT"}');
        $p = Util::b64u((string) json_encode(['sub' => $userId, 'role' => $role, 'iss' => self::ISS, 'aud' => self::AUD, 'iat' => time(), 'exp' => time() + self::TTL]));
        return "$h.$p." . Util::b64u(hash_hmac('sha256', "$h.$p", $secret, true));
    }

    /** @return array{id:string, role:string} */
    public static function verify(string $secret, string $token): array
    {
        $parts = explode('.', $token);
        if (count($parts) !== 3) throw new \RuntimeException('format');
        [$h, $p, $s] = $parts;
        $head = json_decode((string) Util::b64uDecode($h), true);
        if (!is_array($head) || ($head['alg'] ?? '') !== 'HS256') throw new \RuntimeException('alg'); // refuse « none »
        $sig = Util::b64uDecode($s);
        if ($sig === false || !hash_equals(hash_hmac('sha256', "$h.$p", $secret, true), $sig)) throw new \RuntimeException('signature');
        $c = json_decode((string) Util::b64uDecode($p), true);
        if (!is_array($c) || ($c['iss'] ?? '') !== self::ISS || ($c['aud'] ?? '') !== self::AUD) throw new \RuntimeException('claims');
        if (!is_int($c['exp'] ?? null) || $c['exp'] < time() || !is_string($c['sub'] ?? null)) throw new \RuntimeException('exp');
        return ['id' => $c['sub'], 'role' => (string) ($c['role'] ?? 'user')];
    }
}

final class App
{
    public static Db $db;
    public static Settings $settings;
    /** @var array<string,mixed> */
    public static array $config = [];
    public static string $root;      // dossier privé _ovia
    public static string $dataDir;
    /** @var list<array{0:string,1:string,2:callable,3:array<string,mixed>}> */
    private static array $routes = [];
    public static ?Req $req = null;

    // ----------------------------------------------------------- Configuration
    /** Charge config.php ; le crée avec des secrets aléatoires au tout premier lancement. */
    public static function boot(string $root): void
    {
        self::$root = $root;
        $file = $root . '/config.php';
        if (!is_file($file)) {
            self::writeConfig([
                'jwt_secret' => Util::token(48),
                'data_key' => Util::token(32),
                'db_file' => 'ovia-' . bin2hex(random_bytes(8)) . '.sqlite',
                'mysql' => null,
                'created_at' => Util::now(),
            ]);
        }
        $cfg = require $file;
        if (!is_array($cfg) || empty($cfg['jwt_secret']) || empty($cfg['data_key'])) throw new \RuntimeException('config.php illisible');
        self::$config = $cfg;
        self::$dataDir = $root . '/data';
        foreach ([self::$dataDir, self::$dataDir . '/uploads'] as $d) {
            if (!is_dir($d) && !@mkdir($d, 0700, true) && !is_dir($d)) throw new \RuntimeException("dossier non inscriptible : $d");
        }
        self::$db = self::openDb();
        self::$settings = new Settings(self::$db, (string) $cfg['data_key']);
        self::importLegacy(self::$db, self::$settings);
    }

    /** @param array<string,mixed> $cfg */
    public static function writeConfig(array $cfg): void
    {
        $file = self::$root . '/config.php';
        $code = "<?php\n// Généré automatiquement par Ovia. NE PAS partager : contient les clés secrètes du serveur.\n"
            . "// Garde une copie de ce fichier en lieu sûr (sans lui, les réglages chiffrés deviennent illisibles).\n"
            . 'return ' . var_export($cfg, true) . ";\n";
        $tmp = $file . '.' . bin2hex(random_bytes(4)) . '.tmp';
        if (file_put_contents($tmp, $code, LOCK_EX) === false) throw new \RuntimeException('impossible d\'écrire config.php (droits du dossier _ovia)');
        @chmod($tmp, 0600);
        rename($tmp, $file);
        if (function_exists('opcache_invalidate')) @opcache_invalidate($file, true);
        self::$config = $cfg;
    }

    public static function sqliteFile(): string { return self::$dataDir . '/' . self::$config['db_file']; }

    /** Ouvre les données : MySQL si configuré (en y basculant le fichier une seule fois), sinon le fichier. */
    private static function openDb(): Db
    {
        $file = self::sqliteFile();
        $my = self::$config['mysql'] ?? null;
        if (is_array($my) && !empty($my['name'])) {
            try {
                $db = Db::mysql($my);
            } catch (\Throwable $e) {
                error_log('Ovia : MySQL injoignable — ' . $e->getMessage());
                // Tant que le fichier existe, la bascule n'a pas eu lieu : il reste la référence.
                if (!is_file($file)) throw new AppError(503, 'database_unavailable');
                return self::openFile($file);
            }
            self::ensureSchema($db);
            if (is_file($file)) self::switchToMysql($db, $file);
            return $db;
        }
        return self::openFile($file);
    }

    private static function openFile(string $file): Db
    {
        if (!extension_loaded('pdo_sqlite')) throw new AppError(503, 'storage_unavailable', 'extension PHP pdo_sqlite absente');
        $db = Db::sqlite($file);
        self::ensureSchema($db);
        return $db;
    }

    private static function ensureSchema(Db $db): void
    {
        $marker = self::$dataDir . '/schema-' . $db->driver . '.ok';
        $want = md5(json_encode(Db::migrations()) . ($db->driver === 'mysql' ? json_encode(self::$config['mysql']) : self::$config['db_file']));
        if (@file_get_contents($marker) === $want) return;
        $db->migrate();
        @file_put_contents($marker, $want, LOCK_EX);
    }

    /** Bascule fichier → MySQL : recopie, contrôle du nombre de lignes, puis suppression du fichier. */
    private static function switchToMysql(Db $my, string $file): void
    {
        $lock = fopen(self::$dataDir . '/bascule.lock', 'c');
        if (!$lock || !flock($lock, LOCK_EX)) return;
        try {
            if (!is_file($file)) return; // une autre requête vient de terminer la bascule
            $src = Db::sqlite($file);
            self::ensureSchema($src);
            $expected = $src->countRows();
            $my->importFrom($src);
            if ($my->countRows() !== $expected) throw new \RuntimeException('bascule incomplète : le fichier est conservé');
            unset($src);
            foreach ([$file, $file . '-wal', $file . '-shm', self::$dataDir . '/schema-sqlite.ok'] as $f) {
                if (is_file($f)) @unlink($f);
            }
            error_log("Ovia : $expected lignes basculées du fichier vers MySQL, fichier supprimé.");
        } finally {
            flock($lock, LOCK_UN);
            fclose($lock);
        }
    }

    /**
     * Reprise de l'ancien serveur : le fichier comptes-importes.json (déposé dans _ovia/ ou _ovia/data/)
     * est lu une seule fois. Les comptes absents sont créés (même identifiant, même mot de passe),
     * les réglages fournis sont enregistrés chiffrés, puis le fichier est supprimé.
     */
    private static function importLegacy(Db $db, Settings $settings): void
    {
        $file = null;
        foreach ([self::$dataDir . '/comptes-importes.json', self::$root . '/comptes-importes.json'] as $f) {
            if (is_file($f)) { $file = $f; break; }
        }
        if ($file === null) return;
        $j = json_decode((string) file_get_contents($file), true);
        if (!is_array($j)) { error_log('Ovia : comptes-importes.json illisible, fichier laissé en place'); return; }
        foreach ((array) ($j['users'] ?? []) as $u) {
            if (!is_array($u) || !preg_match(In::UUID, (string) ($u['id'] ?? '')) || empty($u['password_hash'])) continue;
            $phone = isset($u['phone']) && preg_match(In::PHONE, (string) $u['phone']) ? (string) $u['phone'] : null;
            $email = !empty($u['email']) ? mb_strtolower((string) $u['email']) : null;
            if ($db->one('SELECT id FROM users WHERE id=? OR (phone IS NOT NULL AND phone=?) OR (email IS NOT NULL AND email=?)', [$u['id'], $phone, $email])) continue;
            $ts = isset($u['created_at']) ? strtotime((string) $u['created_at']) : false;
            $db->insert('users', [
                'id' => $u['id'], 'email' => $email, 'phone' => $phone,
                'display_name' => Util::clip((string) ($u['display_name'] ?? 'Utilisateur'), 60),
                'password_hash' => (string) $u['password_hash'], 'status' => 'active',
                'role' => in_array($u['role'] ?? '', ['user', 'merchant', 'driver', 'admin'], true) ? $u['role'] : 'user',
                'email_verified' => 0, 'failed_logins' => 0, 'locked_until' => null,
                'created_at' => $ts ? gmdate('Y-m-d H:i:s', $ts) : Util::now(), 'updated_at' => Util::now(),
            ]);
        }
        foreach ((array) ($j['settings'] ?? []) as $k => $v) {
            if (!isset(Settings::DEFS[$k]) || $settings->raw((string) $k) !== null) continue; // un réglage déjà saisi n'est jamais écrasé
            $settings->set((string) $k, is_bool($v) ? ($v ? '1' : '0') : (string) $v);
        }
        @unlink($file);
    }

    // ------------------------------------------------------------------ Routeur
    /** @param array<string,mixed> $opts auth: bool|list<string> (rôles), limit: [max, fenêtre en s] */
    public static function route(string $method, string $pattern, callable $handler, array $opts = []): void
    {
        self::$routes[] = [$method, $pattern, $handler, $opts];
    }

    public static function publicUrl(): string
    {
        $set = self::$settings->str('app.public_url');
        if ($set !== '') return rtrim($set, '/');
        $https = (($_SERVER['HTTPS'] ?? '') !== '' && $_SERVER['HTTPS'] !== 'off') || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
        $host = preg_replace('/[^A-Za-z0-9.:\-]/', '', (string) ($_SERVER['HTTP_HOST'] ?? 'localhost'));
        return ($https ? 'https' : 'http') . '://' . $host;
    }

    public static function run(): void
    {
        $started = false;
        try {
            header('Content-Type: application/json; charset=utf-8');
            header('Cache-Control: no-store');
            header('X-Content-Type-Options: nosniff');
            self::boot(dirname(__DIR__));
            $started = true;
            $req = self::$req = new Req();
            if ($req->method === 'OPTIONS') { http_response_code(204); return; }

            foreach (self::$routes as [$method, $pattern, $handler, $opts]) {
                if ($method !== $req->method) continue;
                $rx = '#^' . preg_replace('#\{(\w+)\}#', '(?P<$1>[^/]+)', $pattern) . '$#';
                if (!preg_match($rx, $req->path, $m)) continue;
                $req->params = array_filter($m, 'is_string', ARRAY_FILTER_USE_KEY);

                [$max, $window] = $opts['limit'] ?? [300, 60];
                self::limit(($opts['limit'] ?? null) ? "r:$pattern:{$req->ip}" : "g:{$req->ip}", $max, $window);

                $auth = $opts['auth'] ?? false;
                if ($auth !== false) {
                    $h = $req->header('Authorization') ?? '';
                    if (!str_starts_with($h, 'Bearer ')) throw AppError::unauthorized('missing_token');
                    try {
                        $req->user = Jwt::verify((string) self::$config['jwt_secret'], substr($h, 7));
                    } catch (\Throwable) {
                        throw AppError::unauthorized('invalid_token');
                    }
                    if (is_array($auth) && !in_array($req->user['role'], $auth, true)) throw AppError::forbidden();
                }
                $out = $handler($req);
                if ($out instanceof RawResponse) { $out->send(); } else { self::send($req->status, $out); }
                self::afterResponse();
                return;
            }
            throw AppError::notFound('route_not_found');
        } catch (AppError $e) {
            // Le détail d'un 5xx n'est jamais renvoyé au client, mais il est journalisé.
            if ($e->status >= 500) error_log("Ovia 5xx {$e->errorCode} : {$e->getMessage()}");
            self::send($e->status, ['error' => $e->errorCode] + ($e->status < 500 && $e->getMessage() !== $e->errorCode ? ['message' => $e->getMessage()] : []));
        } catch (\Throwable $e) {
            error_log('Ovia erreur : ' . $e->getMessage() . ' @ ' . basename($e->getFile()) . ':' . $e->getLine());
            self::send($started ? 500 : 503, ['error' => $started ? 'internal_error' : 'server_not_ready']);
        }
    }

    private static function send(int $status, mixed $data): void
    {
        http_response_code($data === null && $status === 200 ? 204 : $status);
        if ($data !== null) echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE);
    }

    /** Tâches de fond déclenchées après l'envoi de la réponse (pas besoin de tâche planifiée). */
    private static function afterResponse(): void
    {
        if (function_exists('fastcgi_finish_request')) @fastcgi_finish_request();
        try { Jobs::maybeRun(); } catch (\Throwable $e) { error_log('Ovia jobs : ' . $e->getMessage()); }
    }

    // -------------------------------------------------------- Limitation de débit
    public static function limit(string $key, int $max, int $windowSec): void
    {
        $k = substr(hash('sha256', $key), 0, 40);
        $now = time();
        $hits = self::$db->tx(function (Db $db) use ($k, $now, $windowSec): int {
            $row = $db->one('SELECT window_start, hits FROM rate_limits WHERE k=?' . $db->lock(), [$k]);
            if (!$row) {
                $db->insertIgnore('rate_limits', ['k' => $k, 'window_start' => $now, 'hits' => 1]);
                return 1;
            }
            if ((int) $row['window_start'] + $windowSec <= $now) {
                $db->run('UPDATE rate_limits SET window_start=?, hits=1 WHERE k=?', [$now, $k]);
                return 1;
            }
            $db->run('UPDATE rate_limits SET hits=hits+1 WHERE k=?', [$k]);
            return (int) $row['hits'] + 1;
        });
        if ($hits > $max) throw new AppError(429, 'rate_limited');
    }

    // -------------------------------------------------- Notifications et audit
    /** Notification dans l'application ; $email=true l'envoie aussi par e-mail (événements importants). */
    public static function notify(string $userId, string $title, string $body, ?string $link = null, bool $email = false): void
    {
        self::$db->insert('notifications', [
            'user_id' => $userId, 'title' => Util::clip($title, 120), 'body' => Util::clip($body, 500), 'link' => $link,
            'read_at' => null, 'created_at' => Util::now(),
        ]);
        if ($email) Mailer::queueNotice($userId, $title, $body);
    }

    /** @param array<string,mixed> $meta */
    public static function audit(?string $actorId, string $action, string $entity, ?string $entityId = null, array $meta = []): void
    {
        self::$db->insert('audit_log', [
            'actor_id' => $actorId, 'action' => $action, 'entity' => $entity, 'entity_id' => $entityId,
            'meta' => (string) json_encode($meta, JSON_UNESCAPED_UNICODE), 'ip' => self::$req?->ip, 'created_at' => Util::now(),
        ]);
    }

    /** Verrouille la ligne d'un utilisateur (sérialise ses opérations d'argent ou de course). */
    public static function lockUser(string $userId): void
    {
        self::$db->one('SELECT id FROM users WHERE id=?' . self::$db->lock(), [$userId]);
    }
}

/** Réponse non-JSON (image, page HTML de retour de paiement). */
final class RawResponse
{
    /** @param array<string,string> $headers */
    public function __construct(private string $body, private string $type, private array $headers = [], private int $status = 200) {}

    public function send(): void
    {
        http_response_code($this->status);
        header('Content-Type: ' . $this->type);
        foreach ($this->headers as $k => $v) header("$k: $v");
        echo $this->body;
    }
}
