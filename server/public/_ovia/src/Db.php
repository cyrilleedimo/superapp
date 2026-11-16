<?php
// Accès aux données. Deux modes, même code :
//   • « fichier » (par défaut) : tout est rangé dans un fichier SQLite privé du dossier data/.
//     Aucune base à créer chez l'hébergeur, l'application fonctionne tout de suite.
//   • MySQL : dès que les accès sont renseignés (écran Admin → Réglages, ou config.php),
//     le contenu du fichier est recopié dans la base, puis le fichier est supprimé.
// Le SQL est écrit dans le sous-ensemble commun aux deux moteurs.
declare(strict_types=1);

namespace Ovia;

use PDO;
use PDOException;
use PDOStatement;

final class Db
{
    private int $depth = 0;

    private function __construct(public readonly PDO $pdo, public readonly string $driver) {}

    // ------------------------------------------------------------ Connexions
    public static function sqlite(string $file): self
    {
        $pdo = new PDO('sqlite:' . $file, null, null, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
        $pdo->exec('PRAGMA journal_mode = WAL');
        $pdo->exec('PRAGMA synchronous = NORMAL');
        $pdo->exec('PRAGMA busy_timeout = 8000');
        $pdo->exec('PRAGMA foreign_keys = OFF');
        // lower() de SQLite ignore les accents : on le remplace par la version Unicode de PHP.
        $lower = static fn ($s) => $s === null ? null : mb_strtolower((string) $s, 'UTF-8');
        if (method_exists($pdo, 'createFunction')) { $pdo->createFunction('lower', $lower, 1); }
        elseif (method_exists($pdo, 'sqliteCreateFunction')) { $pdo->sqliteCreateFunction('lower', $lower, 1); }
        return new self($pdo, 'sqlite');
    }

    /** @param array<string,mixed> $c */
    public static function mysql(array $c): self
    {
        $dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4', $c['host'] ?? 'localhost', (int) ($c['port'] ?? 3306), $c['name'] ?? '');
        $pdo = new PDO($dsn, (string) ($c['user'] ?? ''), (string) ($c['pass'] ?? ''), [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
            PDO::ATTR_STRINGIFY_FETCHES => false,
            PDO::ATTR_TIMEOUT => 8,
        ]);
        $pdo->exec("SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci");
        $pdo->exec("SET time_zone = '+00:00'");
        $pdo->exec("SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ZERO_DATE,NO_ENGINE_SUBSTITUTION'");
        return new self($pdo, 'mysql');
    }

    // --------------------------------------------------------------- Requêtes
    /** @param list<mixed> $args */
    public function q(string $sql, array $args = []): PDOStatement
    {
        $st = $this->pdo->prepare($sql);
        foreach (array_values($args) as $i => $v) {
            $type = match (true) {
                is_int($v) => PDO::PARAM_INT,
                is_bool($v) => PDO::PARAM_INT,
                $v === null => PDO::PARAM_NULL,
                default => PDO::PARAM_STR,
            };
            $st->bindValue($i + 1, is_bool($v) ? (int) $v : (is_float($v) ? (string) $v : $v), $type);
        }
        $st->execute();
        return $st;
    }

    /** @param list<mixed> $args @return list<array<string,mixed>> */
    public function all(string $sql, array $args = []): array { return $this->q($sql, $args)->fetchAll(); }

    /** @param list<mixed> $args @return array<string,mixed>|null */
    public function one(string $sql, array $args = []): ?array
    {
        $r = $this->q($sql, $args)->fetch();
        return $r === false ? null : $r;
    }

    /** @param list<mixed> $args */
    public function val(string $sql, array $args = []): mixed
    {
        $r = $this->q($sql, $args)->fetch(PDO::FETCH_NUM);
        return $r === false ? null : $r[0];
    }

    /** @param list<mixed> $args Nombre de lignes modifiées. */
    public function run(string $sql, array $args = []): int { return $this->q($sql, $args)->rowCount(); }

    /** @param array<string,mixed> $row */
    public function insert(string $table, array $row): void
    {
        $cols = array_keys($row);
        $this->q('INSERT INTO ' . $table . ' (' . implode(',', $cols) . ') VALUES (' . implode(',', array_fill(0, count($cols), '?')) . ')', array_values($row));
    }

    /** Insertion qui ne fait rien si la ligne existe déjà. Renvoie vrai si elle a été créée. @param array<string,mixed> $row */
    public function insertIgnore(string $table, array $row): bool
    {
        $cols = array_keys($row);
        $verb = $this->driver === 'mysql' ? 'INSERT IGNORE' : 'INSERT OR IGNORE';
        return $this->run($verb . ' INTO ' . $table . ' (' . implode(',', $cols) . ') VALUES (' . implode(',', array_fill(0, count($cols), '?')) . ')', array_values($row)) > 0;
    }

    public function lastId(): int { return (int) $this->pdo->lastInsertId(); }

    /** Suffixe de verrou de ligne. En mode fichier, la transaction entière est déjà exclusive. */
    public function lock(): string { return $this->driver === 'mysql' ? ' FOR UPDATE' : ''; }

    /** Liste de « ? » pour une clause IN. @param list<mixed> $items */
    public static function marks(array $items): string { return implode(',', array_fill(0, max(1, count($items)), '?')); }

    public static function isDuplicate(PDOException $e): bool
    {
        return in_array($e->getCode(), ['23000', '23505', 23000], false)
            || str_contains($e->getMessage(), 'UNIQUE constraint') || str_contains($e->getMessage(), 'Duplicate entry');
    }

    /**
     * Transaction : tout ou rien. Mode fichier : verrou d'écriture pris dès le début
     * (deux achats du même article ne peuvent pas se croiser).
     * @template T
     * @param callable(self):T $fn
     * @return T
     */
    public function tx(callable $fn): mixed
    {
        if ($this->depth > 0) return $fn($this); // déjà dans une transaction : on y reste
        $this->driver === 'sqlite' ? $this->pdo->exec('BEGIN IMMEDIATE') : $this->pdo->beginTransaction();
        $this->depth = 1;
        try {
            $out = $fn($this);
            $this->driver === 'sqlite' ? $this->pdo->exec('COMMIT') : $this->pdo->commit();
            return $out;
        } catch (\Throwable $e) {
            try {
                $this->driver === 'sqlite' ? $this->pdo->exec('ROLLBACK') : $this->pdo->rollBack();
            } catch (\Throwable) { /* déjà annulée */ }
            throw $e;
        } finally {
            $this->depth = 0;
        }
    }

    // ------------------------------------------------------------------ Schéma
    /** Tables dans l'ordre de création (et de recopie fichier → MySQL). */
    public const TABLES = [
        'settings', 'users', 'otp_codes', 'refresh_tokens', 'listings', 'orders', 'payments', 'webhook_events',
        'ledger_accounts', 'ledger_entries', 'audit_log', 'media', 'conversations', 'conversation_members', 'offers',
        'messages', 'notifications', 'payouts', 'trips', 'driver_profiles', 'rides', 'stores', 'products',
        'rate_limits', 'mail_outbox',
    ];

    /** @return array<string, list<string>> version => instructions (syntaxe commune, jetons {AUTO} {DT} {TAIL}) */
    public static function migrations(): array
    {
        return ['001_base' => [
            'CREATE TABLE settings (k VARCHAR(80) NOT NULL PRIMARY KEY, v TEXT NOT NULL, secret TINYINT NOT NULL DEFAULT 0, updated_at {DT} NOT NULL){TAIL}',

            'CREATE TABLE users (
               id CHAR(36) NOT NULL PRIMARY KEY, email VARCHAR(190) NULL, phone VARCHAR(20) NULL,
               display_name VARCHAR(60) NOT NULL, password_hash VARCHAR(255) NOT NULL,
               status VARCHAR(12) NOT NULL DEFAULT \'pending\', role VARCHAR(12) NOT NULL DEFAULT \'user\',
               email_verified TINYINT NOT NULL DEFAULT 0, failed_logins INT NOT NULL DEFAULT 0, locked_until {DT} NULL,
               created_at {DT} NOT NULL, updated_at {DT} NOT NULL){TAIL}',
            'CREATE UNIQUE INDEX users_email_uq ON users (email)',
            'CREATE UNIQUE INDEX users_phone_uq ON users (phone)',

            'CREATE TABLE otp_codes (
               id CHAR(36) NOT NULL PRIMARY KEY, user_id CHAR(36) NOT NULL, purpose VARCHAR(20) NOT NULL, target VARCHAR(190) NOT NULL,
               code_hash VARCHAR(64) NOT NULL, bind_hash VARCHAR(64) NULL, attempts INT NOT NULL DEFAULT 0, expires_at {DT} NOT NULL, consumed_at {DT} NULL,
               created_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX otp_user_idx ON otp_codes (user_id, purpose, created_at)',

            'CREATE TABLE refresh_tokens (
               id CHAR(36) NOT NULL PRIMARY KEY, user_id CHAR(36) NOT NULL, family_id CHAR(36) NOT NULL, token_hash VARCHAR(64) NOT NULL,
               expires_at {DT} NOT NULL, revoked_at {DT} NULL, replaced_by CHAR(36) NULL, user_agent VARCHAR(200) NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE UNIQUE INDEX refresh_hash_uq ON refresh_tokens (token_hash)',
            'CREATE INDEX refresh_family_idx ON refresh_tokens (family_id)',
            'CREATE INDEX refresh_user_idx ON refresh_tokens (user_id)',

            'CREATE TABLE listings (
               id CHAR(36) NOT NULL PRIMARY KEY, seller_id CHAR(36) NOT NULL, title VARCHAR(120) NOT NULL, description TEXT NOT NULL,
               category VARCHAR(20) NOT NULL, item_condition VARCHAR(12) NOT NULL, price_xaf BIGINT NOT NULL, city VARCHAR(60) NOT NULL,
               city_key VARCHAR(60) NOT NULL, photos TEXT NOT NULL, search_text TEXT NOT NULL, status VARCHAR(10) NOT NULL DEFAULT \'active\',
               created_at {DT} NOT NULL, updated_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX listings_feed_idx ON listings (status, created_at, id)',
            'CREATE INDEX listings_seller_idx ON listings (seller_id)',

            'CREATE TABLE orders (
               id CHAR(36) NOT NULL PRIMARY KEY, buyer_id CHAR(36) NOT NULL, seller_id CHAR(36) NOT NULL, listing_id CHAR(36) NULL,
               kind VARCHAR(10) NOT NULL DEFAULT \'listing\', ref_id CHAR(36) NULL, items TEXT NOT NULL, fulfillment VARCHAR(12) NULL,
               offer_id CHAR(36) NULL, payment_method VARCHAR(10) NOT NULL DEFAULT \'online\',
               item_price_xaf BIGINT NOT NULL, buyer_fee_xaf BIGINT NOT NULL, total_xaf BIGINT NOT NULL,
               status VARCHAR(16) NOT NULL DEFAULT \'pending_payment\', idempotency_key VARCHAR(64) NOT NULL,
               paid_at {DT} NULL, completed_at {DT} NULL, created_at {DT} NOT NULL, updated_at {DT} NOT NULL){TAIL}',
            'CREATE UNIQUE INDEX orders_idem_uq ON orders (buyer_id, idempotency_key)',
            'CREATE INDEX orders_seller_idx ON orders (seller_id, created_at)',
            'CREATE INDEX orders_status_idx ON orders (status, created_at)',
            'CREATE INDEX orders_listing_idx ON orders (listing_id)',
            'CREATE INDEX orders_ref_idx ON orders (ref_id)',

            'CREATE TABLE payments (
               id CHAR(36) NOT NULL PRIMARY KEY, order_id CHAR(36) NOT NULL, provider VARCHAR(20) NOT NULL, our_reference VARCHAR(80) NOT NULL,
               provider_reference VARCHAR(120) NULL, amount_xaf BIGINT NOT NULL, currency VARCHAR(3) NOT NULL DEFAULT \'XAF\',
               status VARCHAR(12) NOT NULL DEFAULT \'initiated\', checkout_url TEXT NULL, last_provider_data TEXT NULL,
               created_at {DT} NOT NULL, updated_at {DT} NOT NULL){TAIL}',
            'CREATE UNIQUE INDEX payments_ref_uq ON payments (our_reference)',
            'CREATE UNIQUE INDEX payments_pref_uq ON payments (provider_reference)',
            'CREATE INDEX payments_order_idx ON payments (order_id)',

            'CREATE TABLE webhook_events (id {AUTO}, provider VARCHAR(20) NOT NULL, body_sha256 VARCHAR(64) NOT NULL, received_at {DT} NOT NULL){TAIL}',
            'CREATE UNIQUE INDEX webhook_uq ON webhook_events (provider, body_sha256)',

            'CREATE TABLE ledger_accounts (id CHAR(36) NOT NULL PRIMARY KEY, code VARCHAR(60) NOT NULL, kind VARCHAR(12) NOT NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE UNIQUE INDEX ledger_code_uq ON ledger_accounts (code)',
            'CREATE TABLE ledger_entries (
               id {AUTO}, txn_id CHAR(36) NOT NULL, account_id CHAR(36) NOT NULL, amount_xaf BIGINT NOT NULL, order_id CHAR(36) NULL,
               memo VARCHAR(190) NOT NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX ledger_account_idx ON ledger_entries (account_id)',
            'CREATE INDEX ledger_txn_idx ON ledger_entries (txn_id)',

            'CREATE TABLE audit_log (
               id {AUTO}, actor_id CHAR(36) NULL, action VARCHAR(60) NOT NULL, entity VARCHAR(30) NOT NULL, entity_id VARCHAR(64) NULL,
               meta TEXT NOT NULL, ip VARCHAR(45) NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX audit_entity_idx ON audit_log (entity, entity_id)',

            'CREATE TABLE media (
               id CHAR(36) NOT NULL PRIMARY KEY, owner_id CHAR(36) NOT NULL, mime VARCHAR(20) NOT NULL, bytes INT NOT NULL,
               sha256 VARCHAR(64) NOT NULL, storage_key VARCHAR(80) NOT NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE UNIQUE INDEX media_key_uq ON media (storage_key)',

            'CREATE TABLE conversations (
               id CHAR(36) NOT NULL PRIMARY KEY, kind VARCHAR(10) NOT NULL DEFAULT \'listing\', title VARCHAR(80) NULL,
               listing_id CHAR(36) NULL, buyer_id CHAR(36) NULL, seller_id CHAR(36) NULL, direct_key VARCHAR(80) NULL,
               created_by CHAR(36) NOT NULL, last_message_at {DT} NOT NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE UNIQUE INDEX conv_listing_uq ON conversations (listing_id, buyer_id)',
            'CREATE UNIQUE INDEX conv_direct_uq ON conversations (direct_key)',
            'CREATE TABLE conversation_members (
               conversation_id CHAR(36) NOT NULL, user_id CHAR(36) NOT NULL, role VARCHAR(10) NOT NULL DEFAULT \'member\',
               last_read_id BIGINT NOT NULL DEFAULT 0, joined_at {DT} NOT NULL, PRIMARY KEY (conversation_id, user_id)){TAIL}',
            'CREATE INDEX conv_members_user_idx ON conversation_members (user_id)',

            'CREATE TABLE offers (
               id CHAR(36) NOT NULL PRIMARY KEY, conversation_id CHAR(36) NOT NULL, amount_xaf BIGINT NOT NULL,
               status VARCHAR(10) NOT NULL DEFAULT \'pending\', created_at {DT} NOT NULL, decided_at {DT} NULL){TAIL}',
            'CREATE INDEX offers_conv_idx ON offers (conversation_id)',

            'CREATE TABLE messages (
               id {AUTO}, conversation_id CHAR(36) NOT NULL, sender_id CHAR(36) NOT NULL, kind VARCHAR(10) NOT NULL DEFAULT \'text\',
               body TEXT NOT NULL, media_id CHAR(36) NULL, offer_id CHAR(36) NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX messages_conv_idx ON messages (conversation_id, id)',

            'CREATE TABLE notifications (
               id {AUTO}, user_id CHAR(36) NOT NULL, title VARCHAR(120) NOT NULL, body VARCHAR(500) NOT NULL, link VARCHAR(190) NULL,
               read_at {DT} NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX notifications_user_idx ON notifications (user_id, id)',

            'CREATE TABLE payouts (
               id CHAR(36) NOT NULL PRIMARY KEY, user_id CHAR(36) NOT NULL, amount_xaf BIGINT NOT NULL, msisdn VARCHAR(20) NOT NULL,
               channel VARCHAR(16) NOT NULL, status VARCHAR(10) NOT NULL DEFAULT \'requested\', processed_by CHAR(36) NULL,
               processed_at {DT} NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX payouts_user_idx ON payouts (user_id, created_at)',

            'CREATE TABLE trips (
               id CHAR(36) NOT NULL PRIMARY KEY, driver_id CHAR(36) NOT NULL, from_city VARCHAR(60) NOT NULL, to_city VARCHAR(60) NOT NULL,
               from_key VARCHAR(60) NOT NULL, to_key VARCHAR(60) NOT NULL, depart_at {DT} NOT NULL, seats_total INT NOT NULL,
               seats_left INT NOT NULL, price_per_seat_xaf BIGINT NOT NULL, notes VARCHAR(500) NOT NULL DEFAULT \'\',
               status VARCHAR(10) NOT NULL DEFAULT \'open\', created_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX trips_search_idx ON trips (from_key, to_key, depart_at)',

            'CREATE TABLE driver_profiles (
               user_id CHAR(36) NOT NULL PRIMARY KEY, vehicle VARCHAR(80) NOT NULL, plate VARCHAR(20) NOT NULL, verified TINYINT NOT NULL DEFAULT 0,
               online TINYINT NOT NULL DEFAULT 0, lat DOUBLE NULL, lng DOUBLE NULL, updated_at {DT} NOT NULL){TAIL}',

            'CREATE TABLE rides (
               id CHAR(36) NOT NULL PRIMARY KEY, rider_id CHAR(36) NOT NULL, driver_id CHAR(36) NULL, pickup_text VARCHAR(200) NOT NULL,
               pickup_lat DOUBLE NOT NULL, pickup_lng DOUBLE NOT NULL, dropoff_text VARCHAR(200) NOT NULL, dropoff_lat DOUBLE NOT NULL,
               dropoff_lng DOUBLE NOT NULL, distance_km DOUBLE NOT NULL, fare_xaf BIGINT NOT NULL, payment VARCHAR(10) NOT NULL DEFAULT \'cash\',
               status VARCHAR(12) NOT NULL DEFAULT \'requested\', created_at {DT} NOT NULL, updated_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX rides_rider_idx ON rides (rider_id, status)',
            'CREATE INDEX rides_driver_idx ON rides (driver_id, status)',
            'CREATE INDEX rides_status_idx ON rides (status, created_at)',

            'CREATE TABLE stores (
               id CHAR(36) NOT NULL PRIMARY KEY, owner_id CHAR(36) NOT NULL, kind VARCHAR(12) NOT NULL, name VARCHAR(80) NOT NULL,
               description TEXT NOT NULL, city VARCHAR(60) NOT NULL, city_key VARCHAR(60) NOT NULL, address VARCHAR(200) NOT NULL DEFAULT \'\',
               delivery_fee_xaf BIGINT NOT NULL DEFAULT 0, is_open TINYINT NOT NULL DEFAULT 1, approved TINYINT NOT NULL DEFAULT 0,
               created_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX stores_list_idx ON stores (kind, approved, city_key)',
            'CREATE INDEX stores_owner_idx ON stores (owner_id)',

            'CREATE TABLE products (
               id CHAR(36) NOT NULL PRIMARY KEY, store_id CHAR(36) NOT NULL, name VARCHAR(120) NOT NULL, description TEXT NOT NULL,
               category VARCHAR(60) NOT NULL DEFAULT \'\', price_xaf BIGINT NOT NULL, stock INT NULL, available TINYINT NOT NULL DEFAULT 1,
               photo_url VARCHAR(500) NULL, created_at {DT} NOT NULL){TAIL}',
            'CREATE INDEX products_store_idx ON products (store_id)',

            'CREATE TABLE rate_limits (k VARCHAR(120) NOT NULL PRIMARY KEY, window_start BIGINT NOT NULL, hits INT NOT NULL){TAIL}',

            'CREATE TABLE mail_outbox (
               id {AUTO}, to_email VARCHAR(190) NOT NULL, subject VARCHAR(190) NOT NULL, code VARCHAR(10) NULL,
               status VARCHAR(10) NOT NULL, error VARCHAR(250) NULL, created_at {DT} NOT NULL){TAIL}',
        ], '002_exemples' => [
            // Annonces d'exemple du lancement : visibles, mais achetables seulement par un admin.
            'ALTER TABLE listings ADD COLUMN is_demo TINYINT NOT NULL DEFAULT 0',
        ]];
    }

    public function ddl(string $sql): string
    {
        $map = $this->driver === 'mysql'
            ? ['{AUTO}' => 'BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY', '{DT}' => 'DATETIME', '{TAIL}' => ' ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci']
            : ['{AUTO}' => 'INTEGER PRIMARY KEY AUTOINCREMENT', '{DT}' => 'TEXT', '{TAIL}' => ''];
        return strtr($sql, $map);
    }

    /** Crée ou met à niveau les tables. Sans effet si tout est déjà à jour. */
    public function migrate(): void
    {
        $this->pdo->exec($this->ddl('CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(40) NOT NULL PRIMARY KEY, applied_at {DT} NOT NULL){TAIL}'));
        $done = array_column($this->all('SELECT version FROM schema_migrations'), 'version');
        foreach (self::migrations() as $version => $statements) {
            if (in_array($version, $done, true)) continue;
            foreach ($statements as $sql) $this->pdo->exec($this->ddl($sql));
            $this->insertIgnore('schema_migrations', ['version' => $version, 'applied_at' => Util::now()]);
        }
        // Comptes du grand livre toujours présents.
        foreach (['escrow' => 'liability', 'psp:clearing' => 'asset', 'platform:revenue' => 'revenue', 'payouts:pending' => 'liability'] as $code => $kind) {
            if (!$this->one('SELECT id FROM ledger_accounts WHERE code=?', [$code])) {
                $this->insertIgnore('ledger_accounts', ['id' => Util::uuid(), 'code' => $code, 'kind' => $kind, 'created_at' => Util::now()]);
            }
        }
    }

    /** Recopie tout le contenu d'une base (le fichier) vers celle-ci (MySQL). Tout ou rien. */
    public function importFrom(self $src): int
    {
        return $this->tx(function () use ($src): int {
            $n = 0;
            foreach (self::TABLES as $t) {
                $this->pdo->exec('DELETE FROM ' . $t); // la base cible vient d'être créée : seules les lignes d'amorçage partent
                $st = $src->pdo->query('SELECT * FROM ' . $t);
                while ($row = $st->fetch(PDO::FETCH_ASSOC)) {
                    $this->insert($t, $row);
                    $n++;
                }
            }
            return $n;
        });
    }

    public function countRows(): int
    {
        $n = 0;
        foreach (self::TABLES as $t) $n += (int) $this->val('SELECT count(*) FROM ' . $t);
        return $n;
    }
}
