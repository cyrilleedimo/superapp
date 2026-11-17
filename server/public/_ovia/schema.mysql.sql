-- Ovia — schéma MySQL / MariaDB (généré par tools/dump-schema.php, ne pas modifier à la main)
-- Import : phpMyAdmin → ta base → Importer. Le serveur sait aussi créer ces tables tout seul.
-- Toutes les tables commencent par « ovia_ » : ce fichier n'en modifie ni n'en supprime aucune autre.
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS ovia_schema_migrations (version VARCHAR(40) NOT NULL PRIMARY KEY, applied_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---- 001_base
CREATE TABLE ovia_settings (k VARCHAR(80) NOT NULL PRIMARY KEY, v TEXT NOT NULL, secret TINYINT NOT NULL DEFAULT 0, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE ovia_users (
  id CHAR(36) NOT NULL PRIMARY KEY, email VARCHAR(190) NULL, phone VARCHAR(20) NULL,
  display_name VARCHAR(60) NOT NULL, password_hash VARCHAR(255) NOT NULL,
  status VARCHAR(12) NOT NULL DEFAULT 'pending', role VARCHAR(12) NOT NULL DEFAULT 'user',
  email_verified TINYINT NOT NULL DEFAULT 0, failed_logins INT NOT NULL DEFAULT 0, locked_until DATETIME NULL,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX users_email_uq ON ovia_users (email);
CREATE UNIQUE INDEX users_phone_uq ON ovia_users (phone);
CREATE TABLE ovia_otp_codes (
  id CHAR(36) NOT NULL PRIMARY KEY, user_id CHAR(36) NOT NULL, purpose VARCHAR(20) NOT NULL, target VARCHAR(190) NOT NULL,
  code_hash VARCHAR(64) NOT NULL, bind_hash VARCHAR(64) NULL, attempts INT NOT NULL DEFAULT 0, expires_at DATETIME NOT NULL, consumed_at DATETIME NULL,
  created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX otp_user_idx ON ovia_otp_codes (user_id, purpose, created_at);
CREATE TABLE ovia_refresh_tokens (
  id CHAR(36) NOT NULL PRIMARY KEY, user_id CHAR(36) NOT NULL, family_id CHAR(36) NOT NULL, token_hash VARCHAR(64) NOT NULL,
  expires_at DATETIME NOT NULL, revoked_at DATETIME NULL, replaced_by CHAR(36) NULL, user_agent VARCHAR(200) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX refresh_hash_uq ON ovia_refresh_tokens (token_hash);
CREATE INDEX refresh_family_idx ON ovia_refresh_tokens (family_id);
CREATE INDEX refresh_user_idx ON ovia_refresh_tokens (user_id);
CREATE TABLE ovia_listings (
  id CHAR(36) NOT NULL PRIMARY KEY, seller_id CHAR(36) NOT NULL, title VARCHAR(120) NOT NULL, description TEXT NOT NULL,
  category VARCHAR(20) NOT NULL, item_condition VARCHAR(12) NOT NULL, price_xaf BIGINT NOT NULL, city VARCHAR(60) NOT NULL,
  city_key VARCHAR(60) NOT NULL, photos TEXT NOT NULL, search_text TEXT NOT NULL, status VARCHAR(10) NOT NULL DEFAULT 'active',
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX listings_feed_idx ON ovia_listings (status, created_at, id);
CREATE INDEX listings_seller_idx ON ovia_listings (seller_id);
CREATE TABLE ovia_orders (
  id CHAR(36) NOT NULL PRIMARY KEY, buyer_id CHAR(36) NOT NULL, seller_id CHAR(36) NOT NULL, listing_id CHAR(36) NULL,
  kind VARCHAR(10) NOT NULL DEFAULT 'listing', ref_id CHAR(36) NULL, items TEXT NOT NULL, fulfillment VARCHAR(12) NULL,
  offer_id CHAR(36) NULL, payment_method VARCHAR(10) NOT NULL DEFAULT 'online',
  item_price_xaf BIGINT NOT NULL, buyer_fee_xaf BIGINT NOT NULL, total_xaf BIGINT NOT NULL,
  status VARCHAR(16) NOT NULL DEFAULT 'pending_payment', idempotency_key VARCHAR(64) NOT NULL,
  paid_at DATETIME NULL, completed_at DATETIME NULL, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX orders_idem_uq ON ovia_orders (buyer_id, idempotency_key);
CREATE INDEX orders_seller_idx ON ovia_orders (seller_id, created_at);
CREATE INDEX orders_status_idx ON ovia_orders (status, created_at);
CREATE INDEX orders_listing_idx ON ovia_orders (listing_id);
CREATE INDEX orders_ref_idx ON ovia_orders (ref_id);
CREATE TABLE ovia_payments (
  id CHAR(36) NOT NULL PRIMARY KEY, order_id CHAR(36) NOT NULL, provider VARCHAR(20) NOT NULL, our_reference VARCHAR(80) NOT NULL,
  provider_reference VARCHAR(120) NULL, amount_xaf BIGINT NOT NULL, currency VARCHAR(3) NOT NULL DEFAULT 'XAF',
  status VARCHAR(12) NOT NULL DEFAULT 'initiated', checkout_url TEXT NULL, last_provider_data TEXT NULL,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX payments_ref_uq ON ovia_payments (our_reference);
CREATE UNIQUE INDEX payments_pref_uq ON ovia_payments (provider_reference);
CREATE INDEX payments_order_idx ON ovia_payments (order_id);
CREATE TABLE ovia_webhook_events (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, provider VARCHAR(20) NOT NULL, body_sha256 VARCHAR(64) NOT NULL, received_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX webhook_uq ON ovia_webhook_events (provider, body_sha256);
CREATE TABLE ovia_ledger_accounts (id CHAR(36) NOT NULL PRIMARY KEY, code VARCHAR(60) NOT NULL, kind VARCHAR(12) NOT NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX ledger_code_uq ON ovia_ledger_accounts (code);
CREATE TABLE ovia_ledger_entries (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, txn_id CHAR(36) NOT NULL, account_id CHAR(36) NOT NULL, amount_xaf BIGINT NOT NULL, order_id CHAR(36) NULL,
  memo VARCHAR(190) NOT NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX ledger_account_idx ON ovia_ledger_entries (account_id);
CREATE INDEX ledger_txn_idx ON ovia_ledger_entries (txn_id);
CREATE TABLE ovia_audit_log (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, actor_id CHAR(36) NULL, action VARCHAR(60) NOT NULL, entity VARCHAR(30) NOT NULL, entity_id VARCHAR(64) NULL,
  meta TEXT NOT NULL, ip VARCHAR(45) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX audit_entity_idx ON ovia_audit_log (entity, entity_id);
CREATE TABLE ovia_media (
  id CHAR(36) NOT NULL PRIMARY KEY, owner_id CHAR(36) NOT NULL, mime VARCHAR(20) NOT NULL, bytes INT NOT NULL,
  sha256 VARCHAR(64) NOT NULL, storage_key VARCHAR(80) NOT NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX media_key_uq ON ovia_media (storage_key);
CREATE TABLE ovia_conversations (
  id CHAR(36) NOT NULL PRIMARY KEY, kind VARCHAR(10) NOT NULL DEFAULT 'listing', title VARCHAR(80) NULL,
  listing_id CHAR(36) NULL, buyer_id CHAR(36) NULL, seller_id CHAR(36) NULL, direct_key VARCHAR(80) NULL,
  created_by CHAR(36) NOT NULL, last_message_at DATETIME NOT NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE UNIQUE INDEX conv_listing_uq ON ovia_conversations (listing_id, buyer_id);
CREATE UNIQUE INDEX conv_direct_uq ON ovia_conversations (direct_key);
CREATE TABLE ovia_conversation_members (
  conversation_id CHAR(36) NOT NULL, user_id CHAR(36) NOT NULL, role VARCHAR(10) NOT NULL DEFAULT 'member',
  last_read_id BIGINT NOT NULL DEFAULT 0, joined_at DATETIME NOT NULL, PRIMARY KEY (conversation_id, user_id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX conv_members_user_idx ON ovia_conversation_members (user_id);
CREATE TABLE ovia_offers (
  id CHAR(36) NOT NULL PRIMARY KEY, conversation_id CHAR(36) NOT NULL, amount_xaf BIGINT NOT NULL,
  status VARCHAR(10) NOT NULL DEFAULT 'pending', created_at DATETIME NOT NULL, decided_at DATETIME NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX offers_conv_idx ON ovia_offers (conversation_id);
CREATE TABLE ovia_messages (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, conversation_id CHAR(36) NOT NULL, sender_id CHAR(36) NOT NULL, kind VARCHAR(10) NOT NULL DEFAULT 'text',
  body TEXT NOT NULL, media_id CHAR(36) NULL, offer_id CHAR(36) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX messages_conv_idx ON ovia_messages (conversation_id, id);
CREATE TABLE ovia_notifications (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, user_id CHAR(36) NOT NULL, title VARCHAR(120) NOT NULL, body VARCHAR(500) NOT NULL, link VARCHAR(190) NULL,
  read_at DATETIME NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX notifications_user_idx ON ovia_notifications (user_id, id);
CREATE TABLE ovia_payouts (
  id CHAR(36) NOT NULL PRIMARY KEY, user_id CHAR(36) NOT NULL, amount_xaf BIGINT NOT NULL, msisdn VARCHAR(20) NOT NULL,
  channel VARCHAR(16) NOT NULL, status VARCHAR(10) NOT NULL DEFAULT 'requested', processed_by CHAR(36) NULL,
  processed_at DATETIME NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX payouts_user_idx ON ovia_payouts (user_id, created_at);
CREATE TABLE ovia_trips (
  id CHAR(36) NOT NULL PRIMARY KEY, driver_id CHAR(36) NOT NULL, from_city VARCHAR(60) NOT NULL, to_city VARCHAR(60) NOT NULL,
  from_key VARCHAR(60) NOT NULL, to_key VARCHAR(60) NOT NULL, depart_at DATETIME NOT NULL, seats_total INT NOT NULL,
  seats_left INT NOT NULL, price_per_seat_xaf BIGINT NOT NULL, notes VARCHAR(500) NOT NULL DEFAULT '',
  status VARCHAR(10) NOT NULL DEFAULT 'open', created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX trips_search_idx ON ovia_trips (from_key, to_key, depart_at);
CREATE TABLE ovia_driver_profiles (
  user_id CHAR(36) NOT NULL PRIMARY KEY, vehicle VARCHAR(80) NOT NULL, plate VARCHAR(20) NOT NULL, verified TINYINT NOT NULL DEFAULT 0,
  online TINYINT NOT NULL DEFAULT 0, lat DOUBLE NULL, lng DOUBLE NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE ovia_rides (
  id CHAR(36) NOT NULL PRIMARY KEY, rider_id CHAR(36) NOT NULL, driver_id CHAR(36) NULL, pickup_text VARCHAR(200) NOT NULL,
  pickup_lat DOUBLE NOT NULL, pickup_lng DOUBLE NOT NULL, dropoff_text VARCHAR(200) NOT NULL, dropoff_lat DOUBLE NOT NULL,
  dropoff_lng DOUBLE NOT NULL, distance_km DOUBLE NOT NULL, fare_xaf BIGINT NOT NULL, payment VARCHAR(10) NOT NULL DEFAULT 'cash',
  status VARCHAR(12) NOT NULL DEFAULT 'requested', created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX rides_rider_idx ON ovia_rides (rider_id, status);
CREATE INDEX rides_driver_idx ON ovia_rides (driver_id, status);
CREATE INDEX rides_status_idx ON ovia_rides (status, created_at);
CREATE TABLE ovia_stores (
  id CHAR(36) NOT NULL PRIMARY KEY, owner_id CHAR(36) NOT NULL, kind VARCHAR(12) NOT NULL, name VARCHAR(80) NOT NULL,
  description TEXT NOT NULL, city VARCHAR(60) NOT NULL, city_key VARCHAR(60) NOT NULL, address VARCHAR(200) NOT NULL DEFAULT '',
  delivery_fee_xaf BIGINT NOT NULL DEFAULT 0, is_open TINYINT NOT NULL DEFAULT 1, approved TINYINT NOT NULL DEFAULT 0,
  created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX stores_list_idx ON ovia_stores (kind, approved, city_key);
CREATE INDEX stores_owner_idx ON ovia_stores (owner_id);
CREATE TABLE ovia_products (
  id CHAR(36) NOT NULL PRIMARY KEY, store_id CHAR(36) NOT NULL, name VARCHAR(120) NOT NULL, description TEXT NOT NULL,
  category VARCHAR(60) NOT NULL DEFAULT '', price_xaf BIGINT NOT NULL, stock INT NULL, available TINYINT NOT NULL DEFAULT 1,
  photo_url VARCHAR(500) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE INDEX products_store_idx ON ovia_products (store_id);
CREATE TABLE ovia_rate_limits (k VARCHAR(120) NOT NULL PRIMARY KEY, window_start BIGINT NOT NULL, hits INT NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE ovia_mail_outbox (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, to_email VARCHAR(190) NOT NULL, subject VARCHAR(190) NOT NULL, code VARCHAR(10) NULL,
  status VARCHAR(10) NOT NULL, error VARCHAR(250) NULL, created_at DATETIME NOT NULL) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
INSERT IGNORE INTO ovia_schema_migrations (version, applied_at) VALUES ('001_base', UTC_TIMESTAMP());

-- ---- 002_exemples
ALTER TABLE ovia_listings ADD COLUMN is_demo TINYINT NOT NULL DEFAULT 0;
INSERT IGNORE INTO ovia_schema_migrations (version, applied_at) VALUES ('002_exemples', UTC_TIMESTAMP());

-- ---- 003_mot_de_passe_provisoire
ALTER TABLE ovia_users ADD COLUMN must_change_password TINYINT NOT NULL DEFAULT 0;
INSERT IGNORE INTO ovia_schema_migrations (version, applied_at) VALUES ('003_mot_de_passe_provisoire', UTC_TIMESTAMP());

-- Comptes du grand livre
INSERT IGNORE INTO ovia_ledger_accounts (id, code, kind, created_at) VALUES (UUID(), 'escrow', 'liability', UTC_TIMESTAMP());
INSERT IGNORE INTO ovia_ledger_accounts (id, code, kind, created_at) VALUES (UUID(), 'psp:clearing', 'asset', UTC_TIMESTAMP());
INSERT IGNORE INTO ovia_ledger_accounts (id, code, kind, created_at) VALUES (UUID(), 'platform:revenue', 'revenue', UTC_TIMESTAMP());
INSERT IGNORE INTO ovia_ledger_accounts (id, code, kind, created_at) VALUES (UUID(), 'payouts:pending', 'liability', UTC_TIMESTAMP());
