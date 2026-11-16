<?php
// Briques de base : erreurs métier, validation des entrées, identifiants, dates,
// chiffrement, appels HTTP sortants. Aucune dépendance externe (pas de Composer).
declare(strict_types=1);

namespace Ovia;

/** Erreur métier : un code stable que l'application traduit, et un statut HTTP. */
final class AppError extends \Exception
{
    /** @param array<string,mixed> $extra champs ajoutés à la réponse d'erreur (jamais de secret d'un autre compte) */
    public function __construct(public readonly int $status, public readonly string $errorCode, ?string $message = null, public readonly array $extra = [])
    {
        parent::__construct($message ?? $errorCode);
    }
    public static function bad(string $code, ?string $msg = null): self { return new self(400, $code, $msg); }
    public static function unauthorized(string $code = 'unauthorized'): self { return new self(401, $code); }
    public static function forbidden(string $code = 'forbidden'): self { return new self(403, $code); }
    public static function notFound(string $code = 'not_found'): self { return new self(404, $code); }
    public static function conflict(string $code, ?string $msg = null): self { return new self(409, $code, $msg); }
}

final class Util
{
    public static function uuid(): string
    {
        $b = random_bytes(16);
        $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
        $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
    }

    /** Heure UTC au format stocké en base (triable et comparable comme du texte). */
    public static function now(int $offsetSec = 0): string { return gmdate('Y-m-d H:i:s', time() + $offsetSec); }

    /** Date stockée → ISO 8601 pour l'application. */
    public static function iso(?string $s): ?string
    {
        return $s === null || $s === '' ? null : str_replace(' ', 'T', substr($s, 0, 19)) . 'Z';
    }

    public static function ts(string $stored): int { return (int) strtotime($stored . ' UTC'); }

    public static function token(int $bytes = 32): string { return self::b64u(random_bytes($bytes)); }

    public static function b64u(string $bin): string { return rtrim(strtr(base64_encode($bin), '+/', '-_'), '='); }

    public static function b64uDecode(string $s): string|false
    {
        return base64_decode(strtr($s, '-_', '+/') . str_repeat('=', (4 - strlen($s) % 4) % 4), true);
    }

    public static function otp(): string { return str_pad((string) random_int(0, 999999), 6, '0', STR_PAD_LEFT); }

    /** Minuscules sans accents : sert à la recherche et à la comparaison des villes. */
    public static function fold(string $s): string
    {
        $s = mb_strtolower(trim($s), 'UTF-8');
        $map = ['à'=>'a','â'=>'a','ä'=>'a','á'=>'a','ã'=>'a','ç'=>'c','é'=>'e','è'=>'e','ê'=>'e','ë'=>'e','î'=>'i','ï'=>'i','í'=>'i',
                'ô'=>'o','ö'=>'o','ó'=>'o','õ'=>'o','ù'=>'u','û'=>'u','ü'=>'u','ú'=>'u','ÿ'=>'y','ñ'=>'n','œ'=>'oe','æ'=>'ae','’'=>"'"];
        return preg_replace('/\s+/u', ' ', strtr($s, $map)) ?? $s;
    }

    public static function clip(string $s, int $max): string { return mb_substr($s, 0, $max, 'UTF-8'); }
}

/** Validation des entrées : toute donnée venant du client passe par ici. */
final class In
{
    public const UUID = '/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/';
    public const PHONE = '/^\+[1-9][0-9]{7,14}$/';

    /** @param array<string,mixed> $a */
    public function __construct(private array $a) {}

    private static function fail(string $key, string $why): never
    {
        throw AppError::bad('validation_failed', "$key: $why");
    }

    public function has(string $k): bool { return array_key_exists($k, $this->a) && $this->a[$k] !== null; }

    /** @return list<string> */
    public function keys(): array { return array_keys($this->a); }

    public function str(string $k, int $min, int $max, ?string $default = null): string
    {
        if (!$this->has($k)) {
            if ($default !== null) return $default;
            self::fail($k, 'requis');
        }
        $v = $this->a[$k];
        if (!is_string($v) && !is_int($v)) self::fail($k, 'texte attendu');
        $v = trim((string) $v);
        if (!mb_check_encoding($v, 'UTF-8')) self::fail($k, 'encodage invalide');
        $len = mb_strlen($v, 'UTF-8');
        if ($len < $min || $len > $max) self::fail($k, "longueur entre $min et $max");
        return $v;
    }

    public function optStr(string $k, int $min, int $max): ?string
    {
        if (!$this->has($k) || $this->a[$k] === '') return null;
        return $this->str($k, $min, $max);
    }

    public function int(string $k, int $min, int $max, ?int $default = null): int
    {
        if (!$this->has($k)) {
            if ($default !== null) return $default;
            self::fail($k, 'requis');
        }
        $v = $this->a[$k];
        if (is_string($v) && preg_match('/^-?\d{1,15}$/', $v)) $v = (int) $v;
        if (is_float($v) && floor($v) === $v && abs($v) < 1e15) $v = (int) $v;
        if (!is_int($v)) self::fail($k, 'nombre entier attendu');
        if ($v < $min || $v > $max) self::fail($k, "entre $min et $max");
        return $v;
    }

    public function optInt(string $k, int $min, int $max): ?int
    {
        return $this->has($k) && $this->a[$k] !== '' ? $this->int($k, $min, $max) : null;
    }

    public function num(string $k, float $min, float $max): float
    {
        if (!$this->has($k) || !is_numeric($this->a[$k])) self::fail($k, 'nombre attendu');
        $v = (float) $this->a[$k];
        if (!is_finite($v) || $v < $min || $v > $max) self::fail($k, "entre $min et $max");
        return $v;
    }

    public function bool(string $k, ?bool $default = null): bool
    {
        if (!$this->has($k)) {
            if ($default !== null) return $default;
            self::fail($k, 'requis');
        }
        if (!is_bool($this->a[$k])) self::fail($k, 'vrai ou faux attendu');
        return $this->a[$k];
    }

    /** @param list<string> $allowed */
    public function enum(string $k, array $allowed, ?string $default = null): string
    {
        if (!$this->has($k)) {
            if ($default !== null) return $default;
            self::fail($k, 'requis');
        }
        $v = $this->a[$k];
        if (!is_string($v) || !in_array($v, $allowed, true)) self::fail($k, 'valeur non autorisée');
        return $v;
    }

    public function uuid(string $k): string
    {
        $v = $this->a[$k] ?? null;
        if (!is_string($v) || !preg_match(self::UUID, $v)) self::fail($k, 'identifiant invalide');
        return $v;
    }

    public function optUuid(string $k): ?string { return $this->has($k) ? $this->uuid($k) : null; }

    public function email(string $k): string
    {
        $v = mb_strtolower($this->str($k, 5, 190), 'UTF-8');
        if (!filter_var($v, FILTER_VALIDATE_EMAIL)) self::fail($k, 'adresse e-mail invalide');
        return $v;
    }

    public function phone(string $k): string
    {
        $v = preg_replace('/[\s().-]/', '', $this->str($k, 8, 24)) ?? '';
        if (!preg_match(self::PHONE, $v)) self::fail($k, 'format international attendu, ex. +2376XXXXXXXX');
        return $v;
    }

    public function optPhone(string $k): ?string { return $this->has($k) && $this->a[$k] !== '' ? $this->phone($k) : null; }

    /** @return list<mixed> */
    public function arr(string $k, int $min, int $max): array
    {
        $v = $this->a[$k] ?? ($min === 0 ? [] : null);
        if (!is_array($v) || !array_is_list($v)) self::fail($k, 'liste attendue');
        if (count($v) < $min || count($v) > $max) self::fail($k, "entre $min et $max éléments");
        return $v;
    }

    public function obj(string $k): self
    {
        $v = $this->a[$k] ?? null;
        if (!is_array($v) || array_is_list($v) && $v !== []) self::fail($k, 'objet attendu');
        return new self($v);
    }

    /** Refuse les champs inconnus (mises à jour partielles). @param list<string> $allowed */
    public function only(array $allowed): void
    {
        foreach (array_keys($this->a) as $k) {
            if (!in_array($k, $allowed, true)) self::fail((string) $k, 'champ non autorisé');
        }
    }

    /** Photo : adresse https, ou chemin d'un média envoyé à notre propre API. */
    public static function photo(mixed $u): string
    {
        if (!is_string($u) || strlen($u) > 500
            || !(preg_match('#^https://[^\s]+$#', $u) || preg_match('#^/media/[A-Za-z0-9-]+$#', $u))) {
            self::fail('photo', 'adresse https ou média envoyé');
        }
        return $u;
    }
}

/** Chiffrement au repos (clés API, messages) : libsodium si présent, sinon OpenSSL AES-256-GCM. */
final class Crypto
{
    public static function seal(string $plain, string $key): string
    {
        $k = hash('sha256', $key, true);
        if (function_exists('sodium_crypto_secretbox')) {
            $n = random_bytes(SODIUM_CRYPTO_SECRETBOX_NONCEBYTES);
            return 's1:' . base64_encode($n . sodium_crypto_secretbox($plain, $n, $k));
        }
        $iv = random_bytes(12);
        $tag = '';
        $ct = openssl_encrypt($plain, 'aes-256-gcm', $k, OPENSSL_RAW_DATA, $iv, $tag);
        if ($ct === false) throw new \RuntimeException('chiffrement impossible');
        return 'o1:' . base64_encode($iv . $tag . $ct);
    }

    public static function open(string $sealed, string $key): ?string
    {
        $k = hash('sha256', $key, true);
        $raw = base64_decode(substr($sealed, 3), true);
        if ($raw === false) return null;
        if (str_starts_with($sealed, 's1:') && function_exists('sodium_crypto_secretbox_open')) {
            if (strlen($raw) < SODIUM_CRYPTO_SECRETBOX_NONCEBYTES + 16) return null;
            $out = sodium_crypto_secretbox_open(substr($raw, SODIUM_CRYPTO_SECRETBOX_NONCEBYTES), substr($raw, 0, SODIUM_CRYPTO_SECRETBOX_NONCEBYTES), $k);
            return $out === false ? null : $out;
        }
        if (str_starts_with($sealed, 'o1:') && strlen($raw) > 28) {
            $out = openssl_decrypt(substr($raw, 28), 'aes-256-gcm', $k, OPENSSL_RAW_DATA, substr($raw, 0, 12), substr($raw, 12, 16));
            return $out === false ? null : $out;
        }
        return null;
    }

    /** Hachage de mot de passe : argon2id si PHP le propose, sinon bcrypt (coût 12). */
    public static function hashPassword(string $password): string
    {
        if (defined('PASSWORD_ARGON2ID')) {
            return password_hash($password, PASSWORD_ARGON2ID, ['memory_cost' => 19456, 'time_cost' => 2, 'threads' => 1]);
        }
        return password_hash($password, PASSWORD_BCRYPT, ['cost' => 12]);
    }

    public static function verifyPassword(string $password, string $hash): bool
    {
        if (str_starts_with($hash, '$argon2id$') && !defined('PASSWORD_ARGON2ID')) {
            // Comptes repris de l'ancien serveur (argon2id) sur un PHP sans argon2 : libsodium sait les vérifier.
            return function_exists('sodium_crypto_pwhash_str_verify') && sodium_crypto_pwhash_str_verify($hash, $password);
        }
        return password_verify($password, $hash);
    }

    public static function needsRehash(string $hash): bool
    {
        return defined('PASSWORD_ARGON2ID') ? !str_starts_with($hash, '$argon2id$') : !str_starts_with($hash, '$2y$');
    }
}

/** Appels HTTP sortants (prestataire de paiement, IA) : cURL si présent, sinon flux PHP. */
final class Http
{
    /**
     * @param array<string,string> $headers
     * @return array{status:int, body:string}
     */
    public static function request(string $method, string $url, array $headers = [], ?string $body = null, int $timeout = 20): array
    {
        if (!str_starts_with($url, 'https://')) throw new \RuntimeException('seules les adresses https sont autorisées');
        $hdr = [];
        foreach ($headers as $k => $v) $hdr[] = "$k: $v";
        if (function_exists('curl_init')) {
            $ch = curl_init($url);
            curl_setopt_array($ch, [
                CURLOPT_CUSTOMREQUEST => $method, CURLOPT_RETURNTRANSFER => true, CURLOPT_HTTPHEADER => $hdr,
                CURLOPT_TIMEOUT => $timeout, CURLOPT_CONNECTTIMEOUT => 10, CURLOPT_FOLLOWLOCATION => false,
                CURLOPT_SSL_VERIFYPEER => true, CURLOPT_SSL_VERIFYHOST => 2,
                CURLOPT_PROTOCOLS => CURLPROTO_HTTPS,
            ]);
            if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
            $out = curl_exec($ch);
            $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
            $err = curl_error($ch);
            curl_close($ch);
            if ($out === false) throw new \RuntimeException("réseau : $err");
            return ['status' => $status, 'body' => (string) $out];
        }
        $ctx = stream_context_create(['http' => [
            'method' => $method, 'header' => implode("\r\n", $hdr), 'content' => $body ?? '',
            'timeout' => $timeout, 'ignore_errors' => true, 'follow_location' => 0,
        ], 'ssl' => ['verify_peer' => true, 'verify_peer_name' => true]]);
        $out = @file_get_contents($url, false, $ctx);
        if ($out === false) throw new \RuntimeException('réseau : connexion impossible');
        $status = 0;
        foreach ($http_response_header ?? [] as $h) {
            if (preg_match('#^HTTP/\S+\s+(\d{3})#', $h, $m)) $status = (int) $m[1];
        }
        return ['status' => $status, 'body' => $out];
    }

    /**
     * @param array<string,string> $headers
     * @return array{status:int, json:array<string,mixed>}
     */
    public static function json(string $method, string $url, array $headers = [], mixed $payload = null, int $timeout = 20): array
    {
        $headers += ['Accept' => 'application/json'];
        $body = null;
        if ($payload !== null) {
            $headers['Content-Type'] = 'application/json';
            $body = json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
        }
        $r = self::request($method, $url, $headers, $body, $timeout);
        $j = json_decode($r['body'], true);
        return ['status' => $r['status'], 'json' => is_array($j) ? $j : []];
    }
}
