-- =====================================================================
-- 002_phase2_3.sql — Médias, messagerie & offres, notifications, retraits,
-- covoiturage, VTC, restaurants & boutiques, commandes multi-services.
-- =====================================================================

-- ------------------------------------------- Commandes multi-services
ALTER TABLE orders ALTER COLUMN listing_id DROP NOT NULL;
ALTER TABLE orders ADD COLUMN kind text NOT NULL DEFAULT 'listing'
  CHECK (kind IN ('listing','carpool','food','shop'));
ALTER TABLE orders ADD COLUMN ref_id uuid;                 -- trajet / commerce concerné
ALTER TABLE orders ADD COLUMN items jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE orders ADD COLUMN fulfillment text            -- côté vendeur / commerçant
  CHECK (fulfillment IN ('accepted','preparing','ready','delivering','delivered'));
ALTER TABLE orders ADD COLUMN offer_id uuid;
ALTER TABLE orders ADD CONSTRAINT orders_listing_kind CHECK ((kind = 'listing') = (listing_id IS NOT NULL));
CREATE INDEX orders_pending_idx ON orders (status, created_at) WHERE status IN ('pending_payment','paid');
CREATE INDEX orders_ref_idx ON orders (ref_id);

-- --------------------------------------------------------------- Médias
CREATE TABLE media (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id    uuid NOT NULL REFERENCES users(id),
  mime        text NOT NULL CHECK (mime IN ('image/jpeg','image/png','image/webp')),
  bytes       int  NOT NULL CHECK (bytes > 0 AND bytes <= 5242880),
  sha256      text NOT NULL,
  storage_key text NOT NULL UNIQUE,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ------------------------------------------------- Messagerie & offres
CREATE TABLE conversations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id       uuid NOT NULL REFERENCES listings(id),
  buyer_id         uuid NOT NULL REFERENCES users(id),
  seller_id        uuid NOT NULL REFERENCES users(id),
  last_message_at  timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (buyer_id <> seller_id),
  UNIQUE (listing_id, buyer_id)
);
CREATE INDEX conversations_users_idx ON conversations (buyer_id, seller_id, last_message_at DESC);

CREATE TABLE offers (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id  uuid NOT NULL REFERENCES conversations(id),
  amount_xaf       bigint NOT NULL CHECK (amount_xaf > 0),
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','declined','used')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  decided_at       timestamptz
);

CREATE TABLE messages (
  id               bigserial PRIMARY KEY,
  conversation_id  uuid NOT NULL REFERENCES conversations(id),
  sender_id        uuid NOT NULL REFERENCES users(id),
  body             text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 2000),
  offer_id         uuid REFERENCES offers(id),
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX messages_conv_idx ON messages (conversation_id, id);

-- -------------------------------------------------------- Notifications
CREATE TABLE notifications (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES users(id),
  title       text NOT NULL,
  body        text NOT NULL,
  link        text,
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notifications_user_idx ON notifications (user_id, id DESC);

-- ------------------------------------------------------------- Retraits
CREATE TABLE payouts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id),
  amount_xaf    bigint NOT NULL CHECK (amount_xaf > 0),
  msisdn        text NOT NULL CHECK (msisdn ~ '^\+[1-9][0-9]{7,14}$'),
  channel       text NOT NULL CHECK (channel IN ('orange_money','mtn_momo')),
  status        text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','paid','rejected')),
  processed_by  uuid REFERENCES users(id),
  processed_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
INSERT INTO ledger_accounts (code, kind) VALUES ('payouts:pending', 'liability');

-- ---------------------------------------------------------- Covoiturage
CREATE TABLE trips (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id           uuid NOT NULL REFERENCES users(id),
  from_city           text NOT NULL,
  to_city             text NOT NULL,
  depart_at           timestamptz NOT NULL,
  seats_total         int NOT NULL CHECK (seats_total BETWEEN 1 AND 8),
  seats_left          int NOT NULL CHECK (seats_left >= 0),
  price_per_seat_xaf  bigint NOT NULL CHECK (price_per_seat_xaf > 0),
  notes               text NOT NULL DEFAULT '' CHECK (char_length(notes) <= 500),
  status              text NOT NULL DEFAULT 'open' CHECK (status IN ('open','cancelled','completed')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (seats_left <= seats_total)
);
CREATE INDEX trips_search_idx ON trips (lower(from_city), lower(to_city), depart_at) WHERE status = 'open';

-- ------------------------------------------------------------------ VTC
CREATE TABLE driver_profiles (
  user_id      uuid PRIMARY KEY REFERENCES users(id),
  vehicle      text NOT NULL CHECK (char_length(vehicle) BETWEEN 2 AND 80),
  plate        text NOT NULL CHECK (char_length(plate) BETWEEN 3 AND 20),
  verified     boolean NOT NULL DEFAULT false,      -- validé par un admin (KYC)
  online       boolean NOT NULL DEFAULT false,
  lat          double precision CHECK (lat BETWEEN -90 AND 90),
  lng          double precision CHECK (lng BETWEEN -180 AND 180),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE rides (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rider_id      uuid NOT NULL REFERENCES users(id),
  driver_id     uuid REFERENCES users(id),
  pickup_text   text NOT NULL,
  pickup_lat    double precision NOT NULL CHECK (pickup_lat BETWEEN -90 AND 90),
  pickup_lng    double precision NOT NULL CHECK (pickup_lng BETWEEN -180 AND 180),
  dropoff_text  text NOT NULL,
  dropoff_lat   double precision NOT NULL CHECK (dropoff_lat BETWEEN -90 AND 90),
  dropoff_lng   double precision NOT NULL CHECK (dropoff_lng BETWEEN -180 AND 180),
  distance_km   numeric(8,2) NOT NULL CHECK (distance_km >= 0),
  fare_xaf      bigint NOT NULL CHECK (fare_xaf > 0),
  payment       text NOT NULL DEFAULT 'cash' CHECK (payment IN ('cash')),
  status        text NOT NULL DEFAULT 'requested'
                CHECK (status IN ('requested','accepted','arrived','in_progress','completed','cancelled')),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CHECK (driver_id IS NULL OR driver_id <> rider_id)
);
-- Un passager n'a qu'une course active à la fois ; un chauffeur aussi.
CREATE UNIQUE INDEX rides_one_active_rider ON rides (rider_id)
  WHERE status IN ('requested','accepted','arrived','in_progress');
CREATE UNIQUE INDEX rides_one_active_driver ON rides (driver_id)
  WHERE status IN ('accepted','arrived','in_progress');

-- ------------------------------------------- Restaurants & boutiques
CREATE TABLE stores (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id         uuid NOT NULL REFERENCES users(id),
  kind             text NOT NULL CHECK (kind IN ('restaurant','shop')),
  name             text NOT NULL CHECK (char_length(name) BETWEEN 2 AND 80),
  description      text NOT NULL DEFAULT '' CHECK (char_length(description) <= 1000),
  city             text NOT NULL,
  address          text NOT NULL DEFAULT '',
  delivery_fee_xaf bigint NOT NULL DEFAULT 0 CHECK (delivery_fee_xaf >= 0),
  is_open          boolean NOT NULL DEFAULT true,
  approved         boolean NOT NULL DEFAULT false,   -- validé par un admin
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX stores_list_idx ON stores (kind, approved, lower(city));

CREATE TABLE products (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id     uuid NOT NULL REFERENCES stores(id),
  name         text NOT NULL CHECK (char_length(name) BETWEEN 2 AND 120),
  description  text NOT NULL DEFAULT '' CHECK (char_length(description) <= 1000),
  category     text NOT NULL DEFAULT '',
  price_xaf    bigint NOT NULL CHECK (price_xaf > 0),
  stock        int CHECK (stock IS NULL OR stock >= 0),  -- NULL = illimité (plats)
  available    boolean NOT NULL DEFAULT true,
  photo_url    text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX products_store_idx ON products (store_id) WHERE available;
