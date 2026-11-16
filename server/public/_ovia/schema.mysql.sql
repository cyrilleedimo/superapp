-- Ovia — schéma MySQL / MariaDB (généré par tools/dump-schema.php, ne pas modifier à la main)
-- Import : phpMyAdmin → ta base → Importer. Le serveur sait aussi créer ces tables tout seul.
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(40) NOT NULL PRIMARY KEY, applied_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---- 001_base
CREATE TABLE settings (k VARCHAR(80) NOT NULL PRIMARY KEY, v TEXT NOT NULL, secret TINYINT NOT NULL DEFAULT 0, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE users (
  id CHAR(36) NOT NULL PRIMARY KEY, email VARCHAR(190) NULL, phone VARCHAR(20) NULL,
  display_name VARCHAR(60) NOT NULL, password_hash VARCHAR(255) NOT NULL,
  status VARCHAR(12) NOT NULL DEFAULT 'pending', role VARCHAR(12) NOT NULL DEFAULT 'user',
  email_verified TINYINT NOT NULL DEFAULT 0, failed_logins INT NOT NULL DEFAULT 0, locked_until DATETIME NULL,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX users_email_uq ON users (email);
CREATE UNIQUE INDEX users_phone_uq ON users (phone);
CREATE TABLE otp_codes (
  id CHAR(36) NOT NULL PRIMARY KEY, user_id CHAR(36) NOT NULL, purpose VARCHAR(20) NOT NULL, target VARCHAR(190) NOT NULL,
  code_hash VARCHAR(64) NOT NULL, bind_hash VARCHAR(64) NULL, attempts INT NOT NULL DEFAULT 0, expires_at DATETIME NOT NULL, consumed_at DATETIME NULL,
  created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX otp_user_idx ON otp_codes (user_id, purpose, created_at);
CREATE TABLE refresh_tokens (
  id CHAR(36) NOT NULL PRIMARY KEY, user_id CHAR(36) NOT NULL, family_id CHAR(36) NOT NULL, token_hash VARCHAR(64) NOT NULL,
  expires_at DATETIME NOT NULL, revoked_at DATETIME NULL, replaced_by CHAR(36) NULL, user_agent VARCHAR(200) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX refresh_hash_uq ON refresh_tokens (token_hash);
CREATE INDEX refresh_family_idx ON refresh_tokens (family_id);
CREATE INDEX refresh_user_idx ON refresh_tokens (user_id);
CREATE TABLE listings (
  id CHAR(36) NOT NULL PRIMARY KEY, seller_id CHAR(36) NOT NULL, title VARCHAR(120) NOT NULL, description TEXT NOT NULL,
  category VARCHAR(20) NOT NULL, item_condition VARCHAR(12) NOT NULL, price_xaf BIGINT NOT NULL, city VARCHAR(60) NOT NULL,
  city_key VARCHAR(60) NOT NULL, photos TEXT NOT NULL, search_text TEXT NOT NULL, status VARCHAR(10) NOT NULL DEFAULT 'active',
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX listings_feed_idx ON listings (status, created_at, id);
CREATE INDEX listings_seller_idx ON listings (seller_id);
CREATE TABLE orders (
  id CHAR(36) NOT NULL PRIMARY KEY, buyer_id CHAR(36) NOT NULL, seller_id CHAR(36) NOT NULL, listing_id CHAR(36) NULL,
  kind VARCHAR(10) NOT NULL DEFAULT 'listing', ref_id CHAR(36) NULL, items TEXT NOT NULL, fulfillment VARCHAR(12) NULL,
  offer_id CHAR(36) NULL, payment_method VARCHAR(10) NOT NULL DEFAULT 'online',
  item_price_xaf BIGINT NOT NULL, buyer_fee_xaf BIGINT NOT NULL, total_xaf BIGINT NOT NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'pending_payment', idempotency_key VARCHAR(64) NOT NULL,
  paid_at DATETIME NULL, completed_at DATETIME NULL, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX orders_idem_uq ON orders (buyer_id, idempotency_key);
CREATE INDEX orders_seller_idx ON orders (seller_id, created_at);
CREATE INDEX orders_status_idx ON orders (status, created_at);
CREATE INDEX orders_listing_idx ON orders (listing_id);
CREATE INDEX orders_ref_idx ON orders (ref_id);
CREATE TABLE payments (
  id CHAR(36) NOT NULL PRIMARY KEY, order_id CHAR(36) NOT NULL, provider VARCHAR(20) NOT NULL, our_reference VARCHAR(80) NOT NULL,
  provider_reference VARCHAR(120) NULL, amount_xaf BIGINT NOT NULL, currency VARCHAR(3) NOT NULL DEFAULT 'XAF',
  status VARCHAR(12) NOT NULL DEFAULT 'initiated', checkout_url TEXT NULL, last_provider_data TEXT NULL,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX payments_ref_uq ON payments (our_reference);
CREATE UNIQUE INDEX payments_pref_uq ON payments (provider_reference);
CREATE INDEX payments_order_idx ON payments (order_id);
CREATE TABLE webhook_events (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, provider VARCHAR(20) NOT NULL, body_sha256 VARCHAR(64) NOT NULL, received_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX webhook_uq ON webhook_events (provider, body_sha256);
CREATE TABLE ledger_accounts (id CHAR(36) NOT NULL PRIMARY KEY, code VARCHAR(60) NOT NULL, kind VARCHAR(12) NOT NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX ledger_code_uq ON ledger_accounts (code);
CREATE TABLE ledger_entries (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, txn_id CHAR(36) NOT NULL, account_id CHAR(36) NOT NULL, amount_xaf BIGINT NOT NULL, order_id CHAR(36) NULL,
  memo VARCHAR(190) NOT NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX ledger_account_idx ON ledger_entries (account_id);
CREATE INDEX ledger_txn_idx ON ledger_entries (txn_id);
CREATE TABLE audit_log (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, actor_id CHAR(36) NULL, action VARCHAR(60) NOT NULL, entity VARCHAR(30) NOT NULL, entity_id VARCHAR(64) NULL,
  meta TEXT NOT NULL, ip VARCHAR(45) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX audit_entity_idx ON audit_log (entity, entity_id);
CREATE TABLE media (
  id CHAR(36) NOT NULL PRIMARY KEY, owner_id CHAR(36) NOT NULL, mime VARCHAR(20) NOT NULL, bytes INT NOT NULL,
  sha256 VARCHAR(64) NOT NULL, storage_key VARCHAR(80) NOT NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX media_key_uq ON media (storage_key);
CREATE TABLE conversations (
  id CHAR(36) NOT NULL PRIMARY KEY, kind VARCHAR(10) NOT NULL DEFAULT 'listing', title VARCHAR(80) NULL,
  listing_id CHAR(36) NULL, buyer_id CHAR(36) NULL, seller_id CHAR(36) NULL, direct_key VARCHAR(80) NULL,
  created_by CHAR(36) NOT NULL, last_message_at DATETIME NOT NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX conv_listing_uq ON conversations (listing_id, buyer_id);
CREATE UNIQUE INDEX conv_direct_uq ON conversations (direct_key);
CREATE TABLE conversation_members (
  conversation_id CHAR(36) NOT NULL, user_id CHAR(36) NOT NULL, role VARCHAR(10) NOT NULL DEFAULT 'member',
  last_read_id BIGINT NOT NULL DEFAULT 0, joined_at DATETIME NOT NULL, PRIMARY KEY (conversation_id, user_id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX conv_members_user_idx ON conversation_members (user_id);
CREATE TABLE offers (
  id CHAR(36) NOT NULL PRIMARY KEY, conversation_id CHAR(36) NOT NULL, amount_xaf BIGINT NOT NULL,
  status VARCHAR(10) NOT NULL DEFAULT 'pending', created_at DATETIME NOT NULL, decided_at DATETIME NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX offers_conv_idx ON offers (conversation_id);
CREATE TABLE messages (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, conversation_id CHAR(36) NOT NULL, sender_id CHAR(36) NOT NULL, kind VARCHAR(10) NOT NULL DEFAULT 'text',
  body TEXT NOT NULL, media_id CHAR(36) NULL, offer_id CHAR(36) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX messages_conv_idx ON messages (conversation_id, id);
CREATE TABLE notifications (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, user_id CHAR(36) NOT NULL, title VARCHAR(120) NOT NULL, body VARCHAR(500) NOT NULL, link VARCHAR(190) NULL,
  read_at DATETIME NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX notifications_user_idx ON notifications (user_id, id);
CREATE TABLE payouts (
  id CHAR(36) NOT NULL PRIMARY KEY, user_id CHAR(36) NOT NULL, amount_xaf BIGINT NOT NULL, msisdn VARCHAR(20) NOT NULL,
  channel VARCHAR(16) NOT NULL, status VARCHAR(10) NOT NULL DEFAULT 'requested', processed_by CHAR(36) NULL,
  processed_at DATETIME NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX payouts_user_idx ON payouts (user_id, created_at);
CREATE TABLE trips (
  id CHAR(36) NOT NULL PRIMARY KEY, driver_id CHAR(36) NOT NULL, from_city VARCHAR(60) NOT NULL, to_city VARCHAR(60) NOT NULL,
  from_key VARCHAR(60) NOT NULL, to_key VARCHAR(60) NOT NULL, depart_at DATETIME NOT NULL, seats_total INT NOT NULL,
  seats_left INT NOT NULL, price_per_seat_xaf BIGINT NOT NULL, notes VARCHAR(500) NOT NULL DEFAULT '',
  status VARCHAR(10) NOT NULL DEFAULT 'open', created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX trips_search_idx ON trips (from_key, to_key, depart_at);
CREATE TABLE driver_profiles (
  user_id CHAR(36) NOT NULL PRIMARY KEY, vehicle VARCHAR(80) NOT NULL, plate VARCHAR(20) NOT NULL, verified TINYINT NOT NULL DEFAULT 0,
  online TINYINT NOT NULL DEFAULT 0, lat DOUBLE NULL, lng DOUBLE NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE rides (
  id CHAR(36) NOT NULL PRIMARY KEY, rider_id CHAR(36) NOT NULL, driver_id CHAR(36) NULL, pickup_text VARCHAR(200) NOT NULL,
  pickup_lat DOUBLE NOT NULL, pickup_lng DOUBLE NOT NULL, dropoff_text VARCHAR(200) NOT NULL, dropoff_lat DOUBLE NOT NULL,
  dropoff_lng DOUBLE NOT NULL, distance_km DOUBLE NOT NULL, fare_xaf BIGINT NOT NULL, payment VARCHAR(10) NOT NULL DEFAULT 'cash',
  status VARCHAR(12) NOT NULL DEFAULT 'requested', created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX rides_rider_idx ON rides (rider_id, status);
CREATE INDEX rides_driver_idx ON rides (driver_id, status);
CREATE INDEX rides_status_idx ON rides (status, created_at);
CREATE TABLE stores (
  id CHAR(36) NOT NULL PRIMARY KEY, owner_id CHAR(36) NOT NULL, kind VARCHAR(12) NOT NULL, name VARCHAR(80) NOT NULL,
  description TEXT NOT NULL, city VARCHAR(60) NOT NULL, city_key VARCHAR(60) NOT NULL, address VARCHAR(200) NOT NULL DEFAULT '',
  delivery_fee_xaf BIGINT NOT NULL DEFAULT 0, is_open TINYINT NOT NULL DEFAULT 1, approved TINYINT NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX stores_list_idx ON stores (kind, approved, city_key);
CREATE INDEX stores_owner_idx ON stores (owner_id);
CREATE TABLE products (
  id CHAR(36) NOT NULL PRIMARY KEY, store_id CHAR(36) NOT NULL, name VARCHAR(120) NOT NULL, description TEXT NOT NULL,
  category VARCHAR(60) NOT NULL DEFAULT '', price_xaf BIGINT NOT NULL, stock INT NULL, available TINYINT NOT NULL DEFAULT 1,
  photo_url VARCHAR(500) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX products_store_idx ON products (store_id);
CREATE TABLE rate_limits (k VARCHAR(120) NOT NULL PRIMARY KEY, window_start BIGINT NOT NULL, hits INT NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE mail_outbox (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, to_email VARCHAR(190) NOT NULL, subject VARCHAR(190) NOT NULL, code VARCHAR(10) NULL,
  status VARCHAR(10) NOT NULL, error VARCHAR(250) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
INSERT IGNORE INTO schema_migrations (version, applied_at) VALUES ('001_base', UTC_TIMESTAMP());

-- Comptes du grand livre
INSERT IGNORE INTO ledger_accounts (id, code, kind, created_at) VALUES (UUID(), 'escrow', 'liability', UTC_TIMESTAMP());
INSERT IGNORE INTO ledger_accounts (id, code, kind, created_at) VALUES (UUID(), 'psp:clearing', 'asset', UTC_TIMESTAMP());
INSERT IGNORE INTO ledger_accounts (id, code, kind, created_at) VALUES (UUID(), 'platform:revenue', 'revenue', UTC_TIMESTAMP());
INSERT IGNORE INTO ledger_accounts (id, code, kind, created_at) VALUES (UUID(), 'payouts:pending', 'liability', UTC_TIMESTAMP());
