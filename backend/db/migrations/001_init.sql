-- =====================================================================
-- 001_init.sql — Schéma initial du super-app (Phase 1)
-- Domaines : identité, seconde main, commandes séquestre, paiements,
-- grand livre en partie double, journal d'audit.
-- Montants : entiers en XAF (le franc CFA n'a pas de subdivision utilisée).
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()

-- ---------------------------------------------------------------- Identité
CREATE TABLE users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone           text NOT NULL UNIQUE CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'), -- E.164
  email           text UNIQUE,
  display_name    text NOT NULL CHECK (char_length(display_name) BETWEEN 2 AND 60),
  password_hash   text NOT NULL,                       -- argon2id
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','active','suspended')),
  role            text NOT NULL DEFAULT 'user'
                  CHECK (role IN ('user','merchant','driver','admin')),
  failed_logins   int  NOT NULL DEFAULT 0,
  locked_until    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Codes à usage unique (SMS). Seul le hash est stocké.
CREATE TABLE otp_codes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose      text NOT NULL CHECK (purpose IN ('verify_phone','reset_password')),
  code_hash    text NOT NULL,
  attempts     int  NOT NULL DEFAULT 0,
  expires_at   timestamptz NOT NULL,
  consumed_at  timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX otp_codes_user_idx ON otp_codes (user_id, purpose, created_at DESC);

-- Jetons de rafraîchissement opaques, rotation + détection de réutilisation par famille.
CREATE TABLE refresh_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  family_id    uuid NOT NULL,
  token_hash   text NOT NULL UNIQUE,                    -- sha256 du jeton
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  replaced_by  uuid REFERENCES refresh_tokens(id),
  user_agent   text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refresh_tokens_family_idx ON refresh_tokens (family_id);

-- ---------------------------------------------------------- Seconde main
CREATE TABLE listings (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id    uuid NOT NULL REFERENCES users(id),
  title        text NOT NULL CHECK (char_length(title) BETWEEN 3 AND 120),
  description  text NOT NULL DEFAULT '' CHECK (char_length(description) <= 4000),
  category     text NOT NULL,
  condition    text NOT NULL CHECK (condition IN ('new','very_good','good','fair')),
  price_xaf    bigint NOT NULL CHECK (price_xaf > 0),
  city         text NOT NULL,
  photos       jsonb NOT NULL DEFAULT '[]'::jsonb,
  status       text NOT NULL DEFAULT 'active'
               CHECK (status IN ('active','reserved','sold','removed')),
  search_doc   tsvector GENERATED ALWAYS AS (
                 to_tsvector('french', coalesce(title,'') || ' ' || coalesce(description,''))
               ) STORED,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX listings_feed_idx   ON listings (status, created_at DESC, id DESC);
CREATE INDEX listings_cat_idx    ON listings (category, status);
CREATE INDEX listings_search_idx ON listings USING gin (search_doc);

-- ------------------------------------------------- Commandes (séquestre)
CREATE TABLE orders (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  buyer_id         uuid NOT NULL REFERENCES users(id),
  seller_id        uuid NOT NULL REFERENCES users(id),
  listing_id       uuid NOT NULL REFERENCES listings(id),
  item_price_xaf   bigint NOT NULL CHECK (item_price_xaf > 0),
  buyer_fee_xaf    bigint NOT NULL CHECK (buyer_fee_xaf >= 0),
  total_xaf        bigint NOT NULL CHECK (total_xaf = item_price_xaf + buyer_fee_xaf),
  status           text NOT NULL DEFAULT 'pending_payment'
                   CHECK (status IN ('pending_payment','paid','completed',
                                     'disputed','refunded','cancelled')),
  idempotency_key  text NOT NULL,
  paid_at          timestamptz,
  completed_at     timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (buyer_id <> seller_id),
  UNIQUE (buyer_id, idempotency_key)
);
-- Une seule commande « vivante » par annonce : empêche la double vente.
CREATE UNIQUE INDEX orders_one_live_per_listing
  ON orders (listing_id) WHERE status IN ('pending_payment','paid','disputed');

-- ------------------------------------------------------------ Paiements
CREATE TABLE payments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id            uuid NOT NULL REFERENCES orders(id),
  provider            text NOT NULL,
  our_reference       text NOT NULL UNIQUE,
  provider_reference  text UNIQUE,
  amount_xaf          bigint NOT NULL CHECK (amount_xaf > 0),
  currency            text NOT NULL DEFAULT 'XAF',
  status              text NOT NULL DEFAULT 'initiated'
                      CHECK (status IN ('initiated','pending','succeeded','failed','refunded','mismatch')),
  checkout_url        text,
  last_provider_data  jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX payments_order_idx ON payments (order_id);

-- Anti-rejeu : chaque corps de webhook n'est traité qu'une fois.
CREATE TABLE webhook_events (
  id            bigserial PRIMARY KEY,
  provider      text NOT NULL,
  body_sha256   text NOT NULL,
  received_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, body_sha256)
);

-- ------------------------------------------- Grand livre (partie double)
-- Convention : montant > 0 = débit, < 0 = crédit. Chaque transaction somme à 0.
CREATE TABLE ledger_accounts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,     -- ex. 'escrow', 'platform:revenue', 'wallet:<user_id>'
  kind        text NOT NULL CHECK (kind IN ('asset','liability','revenue')),
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ledger_entries (
  id          bigserial PRIMARY KEY,
  txn_id      uuid NOT NULL,
  account_id  uuid NOT NULL REFERENCES ledger_accounts(id),
  amount_xaf  bigint NOT NULL CHECK (amount_xaf <> 0),
  order_id    uuid REFERENCES orders(id),
  memo        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ledger_entries_account_idx ON ledger_entries (account_id);
CREATE INDEX ledger_entries_txn_idx ON ledger_entries (txn_id);

-- Le grand livre est en ajout seul : ni UPDATE ni DELETE.
CREATE FUNCTION ledger_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'ledger_entries est en ajout seul';
END $$;
CREATE TRIGGER ledger_no_update BEFORE UPDATE OR DELETE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION ledger_append_only();

-- Vérifie l'équilibre de chaque transaction au COMMIT (contrainte différée).
CREATE FUNCTION ledger_check_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s bigint;
BEGIN
  SELECT coalesce(sum(amount_xaf),0) INTO s FROM ledger_entries WHERE txn_id = NEW.txn_id;
  IF s <> 0 THEN
    RAISE EXCEPTION 'transaction % déséquilibrée (somme = %)', NEW.txn_id, s;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ledger_balanced
  AFTER INSERT ON ledger_entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION ledger_check_balanced();

INSERT INTO ledger_accounts (code, kind) VALUES
  ('escrow', 'liability'),              -- fonds bloqués pour le compte des acheteurs
  ('psp:clearing', 'asset'),            -- créance sur le prestataire de paiement
  ('platform:revenue', 'revenue');      -- frais de protection acheteur

-- ------------------------------------------------------------ Audit
CREATE TABLE audit_log (
  id          bigserial PRIMARY KEY,
  actor_id    uuid,
  action      text NOT NULL,
  entity      text NOT NULL,
  entity_id   text,
  meta        jsonb NOT NULL DEFAULT '{}'::jsonb,
  ip          inet,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_entity_idx ON audit_log (entity, entity_id);
