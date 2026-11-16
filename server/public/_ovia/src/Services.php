<?php
// Compte (notifications, retraits), covoiturage, VTC, restaurants & boutiques, voyages.
declare(strict_types=1);

namespace Ovia;

final class Services
{
    /** Distance à vol d'oiseau (haversine), en km. Estimation, pas un itinéraire routier. */
    public static function haversineKm(float $aLat, float $aLng, float $bLat, float $bLng): float
    {
        $rad = M_PI / 180;
        $dLat = ($bLat - $aLat) * $rad;
        $dLng = ($bLng - $aLng) * $rad;
        $h = sin($dLat / 2) ** 2 + cos($aLat * $rad) * cos($bLat * $rad) * sin($dLng / 2) ** 2;
        return 2 * 6371 * asin(sqrt($h));
    }

    public static function routes(): void
    {
        self::account();
        self::carpool();
        self::rides();
        self::stores();
        // Comparateur de voyages : les prix de vols ne peuvent pas être inventés, ils viennent d'un
        // partenaire de données sous contrat. Tant qu'aucun n'est branché, l'API le dit clairement.
        App::route('GET', '/travel/flights', function (Req $r) {
            $q = $r->query();
            foreach (['from', 'to'] as $k) {
                if (!preg_match('/^[A-Z]{3}$/', $q->str($k, 3, 3))) throw AppError::bad('validation_failed', "$k: code IATA, ex. DLA");
            }
            throw new AppError(503, 'travel_not_configured');
        });
    }

    // ------------------------------------------------------------------ Compte
    private static function account(): void
    {
        $auth = ['auth' => true];
        $admin = ['auth' => ['admin']];
        $db = fn (): Db => App::$db;

        App::route('GET', '/notifications', function (Req $r) use ($db) {
            $rows = $db()->all('SELECT id, title, body, link, read_at, created_at FROM notifications WHERE user_id=? ORDER BY id DESC LIMIT 100', [$r->uid()]);
            return [
                'items' => array_map(fn ($n) => ['id' => (int) $n['id'], 'title' => $n['title'], 'body' => $n['body'], 'link' => $n['link'],
                                                 'read' => $n['read_at'] !== null, 'createdAt' => Util::iso((string) $n['created_at'])], $rows),
                'unread' => (int) $db()->val('SELECT count(*) FROM notifications WHERE user_id=? AND read_at IS NULL', [$r->uid()]),
            ];
        }, $auth);

        // Compteurs légers pour les pastilles (cloche et onglet Messages).
        App::route('GET', '/me/badges', function (Req $r) use ($db) {
            $uid = $r->uid();
            return [
                'notifications' => (int) $db()->val('SELECT count(*) FROM notifications WHERE user_id=? AND read_at IS NULL', [$uid]),
                'messages' => (int) $db()->val('SELECT count(*) FROM messages g JOIN conversation_members m ON m.conversation_id = g.conversation_id AND m.user_id = ?
                                               WHERE g.id > m.last_read_id AND g.sender_id <> ?', [$uid, $uid]),
            ];
        }, $auth + ['limit' => [120, 60]]);

        App::route('POST', '/notifications/read-all', function (Req $r) use ($db) {
            $db()->run('UPDATE notifications SET read_at=? WHERE user_id=? AND read_at IS NULL', [Util::now(), $r->uid()]);
            return null;
        }, $auth);

        App::route('GET', '/payouts', function (Req $r) use ($db) {
            $rows = $db()->all('SELECT id, amount_xaf, msisdn, channel, status, created_at FROM payouts WHERE user_id=? ORDER BY created_at DESC LIMIT 50', [$r->uid()]);
            return ['items' => array_map(fn ($p) => ['id' => $p['id'], 'amountXaf' => (int) $p['amount_xaf'], 'msisdn' => $p['msisdn'], 'channel' => $p['channel'],
                                                     'status' => $p['status'], 'createdAt' => Util::iso((string) $p['created_at'])], $rows)];
        }, $auth);

        // Retrait du porte-monnaie vers Mobile Money. Le mot de passe est redemandé : un téléphone
        // déverrouillé laissé sans surveillance ne suffit pas à vider le compte.
        App::route('POST', '/payouts', function (Req $r) use ($db) {
            $b = $r->body();
            $amount = $b->int('amountXaf', 1, 100000000);
            $msisdn = $b->phone('msisdn');
            $channel = $b->enum('channel', ['orange_money', 'mtn_momo']);
            Auth::requirePassword($r);
            if ($amount < App::$settings->int('payout.min_xaf')) throw AppError::bad('payout_below_minimum');
            $uid = $r->uid();
            $id = $db()->tx(function (Db $db) use ($uid, $amount, $msisdn, $channel): string {
                App::lockUser($uid); // deux demandes simultanées ne peuvent pas dépenser deux fois le même solde
                if ($amount > -Ledger::balance($db, Ledger::wallet($uid))) throw AppError::conflict('insufficient_balance');
                $id = Util::uuid();
                $db->insert('payouts', ['id' => $id, 'user_id' => $uid, 'amount_xaf' => $amount, 'msisdn' => $msisdn, 'channel' => $channel,
                                        'status' => 'requested', 'processed_by' => null, 'processed_at' => null, 'created_at' => Util::now()]);
                Ledger::post($db, 'demande de retrait', null, [[Ledger::wallet($uid), $amount], ['payouts:pending', -$amount]]);
                App::audit($uid, 'payout.request', 'payout', $id);
                return $id;
            });
            $r->status = 201;
            return ['id' => $id, 'status' => 'requested'];
        }, $auth + ['limit' => [5, 60]]);

        // Admin : le virement est fait depuis le tableau de bord du prestataire, puis marqué ici.
        App::route('GET', '/admin/payouts', function () use ($db) {
            $rows = $db()->all("SELECT p.id, p.amount_xaf, p.msisdn, p.channel, p.created_at, u.display_name FROM payouts p
                                JOIN users u ON u.id = p.user_id WHERE p.status='requested' ORDER BY p.created_at");
            return ['items' => array_map(fn ($p) => ['id' => $p['id'], 'amountXaf' => (int) $p['amount_xaf'], 'msisdn' => $p['msisdn'], 'channel' => $p['channel'],
                                                     'createdAt' => Util::iso((string) $p['created_at']), 'userName' => $p['display_name']], $rows)];
        }, $admin);

        App::route('POST', '/admin/payouts/{id}/decision', function (Req $r) use ($db) {
            $paid = $r->body()->bool('paid');
            return $db()->tx(function (Db $db) use ($r, $paid): array {
                $p = $db->one('SELECT user_id, amount_xaf, status FROM payouts WHERE id=?' . $db->lock(), [$r->id()]);
                if (!$p) throw AppError::notFound();
                if ($p['status'] !== 'requested') throw AppError::conflict('payout_already_processed');
                $amount = (int) $p['amount_xaf'];
                Ledger::post($db, $paid ? 'retrait versé' : 'retrait refusé, solde restitué', null,
                    [['payouts:pending', $amount], [$paid ? 'psp:clearing' : Ledger::wallet((string) $p['user_id']), -$amount]]);
                $db->run('UPDATE payouts SET status=?, processed_by=?, processed_at=? WHERE id=?', [$paid ? 'paid' : 'rejected', $r->uid(), Util::now(), $r->id()]);
                App::audit($r->uid(), $paid ? 'payout.paid' : 'payout.rejected', 'payout', $r->id());
                App::notify((string) $p['user_id'], $paid ? 'Retrait envoyé' : 'Retrait refusé',
                    $paid ? "$amount FCFA ont été envoyés sur ton compte Mobile Money." : 'Ton retrait a été refusé, le montant est revenu dans ton porte-monnaie.', '/payouts', true);
                return ['id' => $r->id(), 'status' => $paid ? 'paid' : 'rejected'];
            });
        }, $admin);
    }

    // ------------------------------------------------------------ Covoiturage
    private static function carpool(): void
    {
        $auth = ['auth' => true];
        $db = fn (): Db => App::$db;

        App::route('GET', '/trips', function (Req $r) use ($db) {
            $q = $r->query();
            $args = [Util::fold($q->str('from', 2, 60)), Util::fold($q->str('to', 2, 60)), Util::now()];
            $dateSql = '';
            if ($date = $q->optStr('date', 10, 10)) {
                if (!preg_match('/^\d{4}-\d\d-\d\d$/', $date)) throw AppError::bad('validation_failed', 'date');
                $dateSql = ' AND t.depart_at >= ? AND t.depart_at <= ?';
                array_push($args, "$date 00:00:00", "$date 23:59:59");
            }
            $rows = $db()->all("SELECT t.*, u.display_name FROM trips t JOIN users u ON u.id = t.driver_id
                                WHERE t.status='open' AND t.seats_left > 0 AND t.from_key=? AND t.to_key=? AND t.depart_at > ? $dateSql
                                ORDER BY t.depart_at LIMIT 50", $args);
            return ['items' => array_map(fn ($t) => [
                'id' => $t['id'], 'fromCity' => $t['from_city'], 'toCity' => $t['to_city'], 'departAt' => Util::iso((string) $t['depart_at']),
                'seatsLeft' => (int) $t['seats_left'], 'pricePerSeatXaf' => (int) $t['price_per_seat_xaf'], 'notes' => $t['notes'],
                'driver' => ['id' => $t['driver_id'], 'displayName' => $t['display_name']],
            ], $rows)];
        });

        App::route('GET', '/trips/mine', function (Req $r) use ($db) {
            $rows = $db()->all('SELECT * FROM trips WHERE driver_id=? ORDER BY depart_at DESC LIMIT 50', [$r->uid()]);
            return ['items' => array_map(fn ($t) => [
                'id' => $t['id'], 'fromCity' => $t['from_city'], 'toCity' => $t['to_city'], 'departAt' => Util::iso((string) $t['depart_at']),
                'seatsTotal' => (int) $t['seats_total'], 'seatsLeft' => (int) $t['seats_left'], 'pricePerSeatXaf' => (int) $t['price_per_seat_xaf'], 'status' => $t['status'],
            ], $rows)];
        }, $auth);

        App::route('POST', '/trips', function (Req $r) use ($db) {
            $b = $r->body();
            $from = $b->str('fromCity', 2, 60);
            $to = $b->str('toCity', 2, 60);
            $ts = strtotime($b->str('departAt', 16, 40));
            if ($ts === false) throw AppError::bad('validation_failed', 'departAt');
            if ($ts < time() + 15 * 60) throw AppError::conflict('departure_too_soon');
            $seats = $b->int('seats', 1, 8);
            $id = Util::uuid();
            $db()->insert('trips', ['id' => $id, 'driver_id' => $r->uid(), 'from_city' => $from, 'to_city' => $to, 'from_key' => Util::fold($from), 'to_key' => Util::fold($to),
                                    'depart_at' => gmdate('Y-m-d H:i:s', $ts), 'seats_total' => $seats, 'seats_left' => $seats,
                                    'price_per_seat_xaf' => $b->int('pricePerSeatXaf', 1, 1000000), 'notes' => $b->str('notes', 0, 500, ''),
                                    'status' => 'open', 'created_at' => Util::now()]);
            $r->status = 201;
            return ['id' => $id];
        }, $auth + ['limit' => [20, 60]]);

        App::route('POST', '/trips/{id}/cancel', function (Req $r) use ($db) {
            $ok = $db()->tx(function (Db $db) use ($r): bool {
                $t = $db->one('SELECT driver_id, status FROM trips WHERE id=?' . $db->lock(), [$r->id()]);
                if (!$t || $t['driver_id'] !== $r->uid() || $t['status'] !== 'open') return false;
                if ($db->one("SELECT id FROM orders WHERE ref_id=? AND status IN ('pending_payment','paid','cash_due','disputed') LIMIT 1", [$r->id()])) return false;
                $db->run("UPDATE trips SET status='cancelled' WHERE id=?", [$r->id()]);
                return true;
            });
            if (!$ok) throw AppError::conflict('trip_not_cancellable');
            return ['id' => $r->id(), 'status' => 'cancelled'];
        }, $auth);

        // Réserver des places : verrou sur le trajet, places décrémentées dans la même transaction.
        App::route('POST', '/trips/{id}/book', function (Req $r) use ($db) {
            $seats = $r->body()->int('seats', 1, 8);
            $buyerId = $r->uid();
            $key = $r->idempotencyKey();
            if ($replay = Orders::findReplay($buyerId, $key)) return Orders::view($replay);
            $order = $db()->tx(function (Db $db) use ($r, $seats, $buyerId, $key): array {
                $t = $db->one('SELECT * FROM trips WHERE id=?' . $db->lock(), [$r->id()]);
                if (!$t) throw AppError::notFound('trip_not_found');
                if ($t['driver_id'] === $buyerId) throw AppError::forbidden('own_trip');
                if ($t['status'] !== 'open' || $t['depart_at'] < Util::now()) throw AppError::conflict('trip_unavailable');
                if ((int) $t['seats_left'] < $seats) throw AppError::conflict('not_enough_seats');
                $db->run('UPDATE trips SET seats_left = seats_left - ? WHERE id=?', [$seats, $r->id()]);
                return Orders::insert($db, [
                    'buyerId' => $buyerId, 'sellerId' => (string) $t['driver_id'], 'kind' => 'carpool', 'refId' => $r->id(), 'idempotencyKey' => $key,
                    'items' => [['name' => "{$t['from_city']} → {$t['to_city']}", 'qty' => $seats, 'unitPriceXaf' => (int) $t['price_per_seat_xaf']]],
                    'itemPriceXaf' => $seats * (int) $t['price_per_seat_xaf'],
                ]);
            });
            $r->status = 201;
            return Orders::view($order);
        }, $auth);
    }

    // -------------------------------------------------------------------- VTC
    /** @param array<string,mixed> $x */
    private static function rideView(array $x): array
    {
        return [
            'id' => $x['id'], 'riderId' => $x['rider_id'], 'driverId' => $x['driver_id'], 'pickupText' => $x['pickup_text'],
            'pickupLat' => (float) $x['pickup_lat'], 'pickupLng' => (float) $x['pickup_lng'], 'dropoffText' => $x['dropoff_text'],
            'dropoffLat' => (float) $x['dropoff_lat'], 'dropoffLng' => (float) $x['dropoff_lng'], 'distanceKm' => (float) $x['distance_km'],
            'fareXaf' => (int) $x['fare_xaf'], 'payment' => $x['payment'], 'status' => $x['status'], 'createdAt' => Util::iso((string) $x['created_at']),
        ];
    }

    private static function rides(): void
    {
        $auth = ['auth' => true];
        $admin = ['auth' => ['admin']];
        $db = fn (): Db => App::$db;
        $active = "('requested','accepted','arrived','in_progress')";

        $quote = function (float $pLat, float $pLng, float $dLat, float $dLng): array {
            $perKm = App::$settings->int('rides.per_km_xaf');
            if ($perKm < 1) throw new AppError(503, 'rides_not_configured'); // tarif = décision commerciale, réglée par l'admin
            $km = round(self::haversineKm($pLat, $pLng, $dLat, $dLng), 2);
            if ($km < 0.2) throw AppError::bad('ride_too_short');
            if ($km > 100) throw AppError::bad('ride_too_long');
            return ['distanceKm' => $km, 'fareXaf' => (int) ceil(App::$settings->int('rides.base_xaf') + $km * $perKm)];
        };
        $point = fn (In $p): array => ['text' => $p->str('text', 2, 200), 'lat' => $p->num('lat', -90, 90), 'lng' => $p->num('lng', -180, 180)];

        App::route('POST', '/drivers/apply', function (Req $r) use ($db) {
            $b = $r->body();
            $vehicle = $b->str('vehicle', 2, 80);
            $plate = $b->str('plate', 3, 20);
            if (!$db()->insertIgnore('driver_profiles', ['user_id' => $r->uid(), 'vehicle' => $vehicle, 'plate' => $plate, 'verified' => 0, 'online' => 0,
                                                         'lat' => null, 'lng' => null, 'updated_at' => Util::now()])) {
                $db()->run('UPDATE driver_profiles SET vehicle=?, plate=?, verified=0, online=0, updated_at=? WHERE user_id=?', [$vehicle, $plate, Util::now(), $r->uid()]);
            }
            $r->status = 201;
            return ['status' => 'pending_verification'];
        }, $auth);

        App::route('GET', '/drivers/me', function (Req $r) use ($db) {
            $d = $db()->one('SELECT vehicle, plate, verified, online FROM driver_profiles WHERE user_id=?', [$r->uid()]);
            return $d ? ['vehicle' => $d['vehicle'], 'plate' => $d['plate'], 'verified' => (bool) (int) $d['verified'], 'online' => (bool) (int) $d['online']] : ['applied' => false];
        }, $auth);

        App::route('POST', '/drivers/me/status', function (Req $r) use ($db) {
            $b = $r->body();
            $online = $b->bool('online');
            $lat = $b->has('lat') ? $b->num('lat', -90, 90) : null;
            $lng = $b->has('lng') ? $b->num('lng', -180, 180) : null;
            if ($online && ($lat === null || $lng === null)) throw AppError::bad('location_required');
            if (!$db()->one('SELECT user_id FROM driver_profiles WHERE user_id=? AND verified=1', [$r->uid()])) throw AppError::forbidden('driver_not_verified');
            $db()->run('UPDATE driver_profiles SET online=?, lat=coalesce(?, lat), lng=coalesce(?, lng), updated_at=? WHERE user_id=?',
                [$online ? 1 : 0, $lat, $lng, Util::now(), $r->uid()]);
            return ['online' => $online];
        }, $auth + ['limit' => [120, 60]]);

        App::route('GET', '/admin/drivers', function () use ($db) {
            $rows = $db()->all('SELECT d.user_id, u.display_name, u.phone, d.vehicle, d.plate, d.verified FROM driver_profiles d
                                JOIN users u ON u.id = d.user_id ORDER BY d.verified, d.updated_at DESC LIMIT 200');
            return ['items' => array_map(fn ($d) => ['userId' => $d['user_id'], 'displayName' => $d['display_name'], 'phone' => $d['phone'] ?? '—',
                                                     'vehicle' => $d['vehicle'], 'plate' => $d['plate'], 'verified' => (bool) (int) $d['verified']], $rows)];
        }, $admin);

        App::route('POST', '/admin/drivers/{id}/verify', function (Req $r) use ($db) {
            $verified = $r->body()->bool('verified');
            if (!$db()->one('SELECT user_id FROM driver_profiles WHERE user_id=?', [$r->id()])) throw AppError::notFound();
            $db()->run('UPDATE driver_profiles SET verified=?, online=0, updated_at=? WHERE user_id=?', [$verified ? 1 : 0, Util::now(), $r->id()]);
            App::audit($r->uid(), $verified ? 'driver.verified' : 'driver.revoked', 'user', $r->id());
            App::notify($r->id(), $verified ? 'Compte chauffeur validé' : 'Compte chauffeur suspendu',
                $verified ? 'Tu peux passer en ligne et accepter des courses.' : 'Contacte le support pour plus d\'informations.', '/driver', true);
            return ['userId' => $r->id(), 'verified' => $verified];
        }, $admin);

        App::route('POST', '/rides/estimate', function (Req $r) use ($quote, $point) {
            $p = $point($r->body()->obj('pickup'));
            $d = $point($r->body()->obj('dropoff'));
            return $quote($p['lat'], $p['lng'], $d['lat'], $d['lng']);
        });

        App::route('POST', '/rides', function (Req $r) use ($db, $quote, $point, $active) {
            $p = $point($r->body()->obj('pickup'));
            $d = $point($r->body()->obj('dropoff'));
            $q = $quote($p['lat'], $p['lng'], $d['lat'], $d['lng']);
            $uid = $r->uid();
            $ride = $db()->tx(function (Db $db) use ($uid, $p, $d, $q, $active): array {
                App::lockUser($uid); // un passager n'a qu'une course active à la fois
                if ($db->one("SELECT id FROM rides WHERE rider_id=? AND status IN $active", [$uid])) throw AppError::conflict('ride_already_active');
                $id = Util::uuid();
                $db->insert('rides', ['id' => $id, 'rider_id' => $uid, 'driver_id' => null, 'pickup_text' => $p['text'], 'pickup_lat' => $p['lat'], 'pickup_lng' => $p['lng'],
                                      'dropoff_text' => $d['text'], 'dropoff_lat' => $d['lat'], 'dropoff_lng' => $d['lng'], 'distance_km' => $q['distanceKm'],
                                      'fare_xaf' => $q['fareXaf'], 'payment' => 'cash', 'status' => 'requested', 'created_at' => Util::now(), 'updated_at' => Util::now()]);
                return (array) $db->one('SELECT * FROM rides WHERE id=?', [$id]);
            });
            $r->status = 201;
            return self::rideView($ride);
        }, $auth + ['limit' => [10, 60]]);

        // Course active de l'utilisateur, qu'il soit passager ou chauffeur.
        App::route('GET', '/rides/current', function (Req $r) use ($db, $active) {
            $x = $db()->one("SELECT * FROM rides WHERE (rider_id=? OR driver_id=?) AND status IN $active ORDER BY created_at DESC LIMIT 1", [$r->uid(), $r->uid()]);
            if (!$x) return ['ride' => null];
            $view = self::rideView($x);
            $view['driver'] = null;
            if ($x['driver_id']) {
                $d = $db()->one('SELECT u.display_name, u.phone, d.vehicle, d.plate FROM users u JOIN driver_profiles d ON d.user_id = u.id WHERE u.id=?', [$x['driver_id']]);
                if ($d) $view['driver'] = ['displayName' => $d['display_name'], 'phone' => $d['phone'] ?? '', 'vehicle' => $d['vehicle'], 'plate' => $d['plate']];
            }
            return ['ride' => $view];
        }, $auth + ['limit' => [120, 60]]);

        // Chauffeur en ligne : demandes récentes à proximité.
        App::route('GET', '/rides/nearby', function (Req $r) use ($db) {
            $pos = $db()->one('SELECT lat, lng FROM driver_profiles WHERE user_id=? AND verified=1 AND online=1', [$r->uid()]);
            if (!$pos || $pos['lat'] === null || $pos['lng'] === null) throw AppError::forbidden('driver_not_online');
            $radius = max(1, App::$settings->int('rides.radius_km'));
            $items = [];
            foreach ($db()->all("SELECT * FROM rides WHERE status='requested' AND rider_id <> ? AND created_at > ? ORDER BY created_at LIMIT 100", [$r->uid(), Util::now(-900)]) as $x) {
                $dist = round(self::haversineKm((float) $pos['lat'], (float) $pos['lng'], (float) $x['pickup_lat'], (float) $x['pickup_lng']), 1);
                if ($dist <= $radius) $items[] = self::rideView($x) + ['pickupDistanceKm' => $dist];
            }
            usort($items, fn ($a, $b) => $a['pickupDistanceKm'] <=> $b['pickupDistanceKm']);
            return ['items' => array_slice($items, 0, 20)];
        }, $auth + ['limit' => [120, 60]]);

        // Premier chauffeur qui accepte : verrou de ligne, une seule attribution possible.
        App::route('POST', '/rides/{id}/accept', function (Req $r) use ($db, $active) {
            $driverId = $r->uid();
            return $db()->tx(function (Db $db) use ($r, $driverId, $active): array {
                App::lockUser($driverId);
                if (!$db->one('SELECT user_id FROM driver_profiles WHERE user_id=? AND verified=1 AND online=1', [$driverId])) throw AppError::forbidden('driver_not_online');
                $ride = $db->one('SELECT status, rider_id FROM rides WHERE id=?' . $db->lock(), [$r->id()]);
                if (!$ride) throw AppError::notFound();
                if ($ride['rider_id'] === $driverId) throw AppError::forbidden('own_ride');
                if ($ride['status'] !== 'requested') throw AppError::conflict('ride_already_taken');
                if ($db->one("SELECT id FROM rides WHERE driver_id=? AND status IN $active", [$driverId])) throw AppError::conflict('driver_already_on_ride');
                $db->run("UPDATE rides SET driver_id=?, status='accepted', updated_at=? WHERE id=?", [$driverId, Util::now(), $r->id()]);
                App::notify((string) $ride['rider_id'], 'Chauffeur en route', 'Un chauffeur a accepté ta course.', '/rides');
                return self::rideView((array) $db->one('SELECT * FROM rides WHERE id=?', [$r->id()]));
            });
        }, $auth);

        App::route('POST', '/rides/{id}/status', function (Req $r) use ($db) {
            $status = $r->body()->enum('status', ['arrived', 'in_progress', 'completed']);
            $prev = ['arrived' => 'accepted', 'in_progress' => 'arrived', 'completed' => 'in_progress'];
            return $db()->tx(function (Db $db) use ($r, $status, $prev): array {
                $ride = $db->one('SELECT status, driver_id, rider_id FROM rides WHERE id=?' . $db->lock(), [$r->id()]);
                if (!$ride || $ride['driver_id'] !== $r->uid()) throw AppError::notFound();
                if ($ride['status'] !== $prev[$status]) throw AppError::conflict('invalid_transition');
                $db->run('UPDATE rides SET status=?, updated_at=? WHERE id=?', [$status, Util::now(), $r->id()]);
                $msg = ['arrived' => 'Ton chauffeur est arrivé au point de départ.', 'in_progress' => 'Course démarrée. Bon trajet !',
                        'completed' => 'Course terminée. Merci d\'avoir voyagé avec nous.'];
                App::notify((string) $ride['rider_id'], 'Course', $msg[$status], '/rides');
                if ($status === 'completed') App::audit($r->uid(), 'ride.completed', 'ride', $r->id());
                return self::rideView((array) $db->one('SELECT * FROM rides WHERE id=?', [$r->id()]));
            });
        }, $auth);

        App::route('POST', '/rides/{id}/cancel', function (Req $r) use ($db) {
            $uid = $r->uid();
            return $db()->tx(function (Db $db) use ($r, $uid): array {
                $ride = $db->one('SELECT status, driver_id, rider_id FROM rides WHERE id=?' . $db->lock(), [$r->id()]);
                if (!$ride || ($ride['rider_id'] !== $uid && $ride['driver_id'] !== $uid)) throw AppError::notFound();
                if (!in_array($ride['status'], ['requested', 'accepted', 'arrived'], true)) throw AppError::conflict('ride_not_cancellable');
                $db->run("UPDATE rides SET status='cancelled', updated_at=? WHERE id=?", [Util::now(), $r->id()]);
                $other = $uid === $ride['rider_id'] ? $ride['driver_id'] : $ride['rider_id'];
                if ($other) App::notify((string) $other, 'Course annulée', 'La course a été annulée.', '/rides');
                return ['id' => $r->id(), 'status' => 'cancelled'];
            });
        }, $auth);
    }

    // ------------------------------------------------ Restaurants & boutiques
    /** @param array<string,mixed> $s */
    private static function storeView(array $s): array
    {
        return ['id' => $s['id'], 'ownerId' => $s['owner_id'], 'kind' => $s['kind'], 'name' => $s['name'], 'description' => $s['description'],
                'city' => $s['city'], 'address' => $s['address'], 'deliveryFeeXaf' => (int) $s['delivery_fee_xaf'], 'isOpen' => (bool) (int) $s['is_open'],
                'approved' => (bool) (int) $s['approved'], 'createdAt' => Util::iso((string) $s['created_at'])];
    }

    /** @param array<string,mixed> $p */
    private static function productView(array $p): array
    {
        return ['id' => $p['id'], 'storeId' => $p['store_id'], 'name' => $p['name'], 'description' => $p['description'], 'category' => $p['category'],
                'priceXaf' => (int) $p['price_xaf'], 'stock' => $p['stock'] === null ? null : (int) $p['stock'],
                'available' => (bool) (int) $p['available'], 'photoUrl' => $p['photo_url']];
    }

    private static function stores(): void
    {
        $auth = ['auth' => true];
        $admin = ['auth' => ['admin']];
        $db = fn (): Db => App::$db;
        $owned = function (string $storeId, string $userId) use ($db): array {
            $s = $db()->one('SELECT * FROM stores WHERE id=?', [$storeId]);
            if (!$s) throw AppError::notFound();
            if ($s['owner_id'] !== $userId) throw AppError::forbidden();
            return $s;
        };

        App::route('GET', '/stores', function (Req $r) use ($db) {
            $q = $r->query();
            $args = [$q->enum('kind', ['restaurant', 'shop'])];
            $citySql = '';
            if ($city = $q->optStr('city', 1, 60)) { $citySql = ' AND city_key=?'; $args[] = Util::fold($city); }
            return ['items' => array_map([self::class, 'storeView'],
                $db()->all("SELECT * FROM stores WHERE kind=? AND approved=1 $citySql ORDER BY is_open DESC, name LIMIT 100", $args))];
        });

        App::route('GET', '/stores/mine', function (Req $r) use ($db) {
            return ['items' => array_map([self::class, 'storeView'], $db()->all('SELECT * FROM stores WHERE owner_id=? ORDER BY created_at', [$r->uid()]))];
        }, $auth);

        App::route('GET', '/stores/{id}', function (Req $r) use ($db) {
            $s = $db()->one('SELECT * FROM stores WHERE id=?', [$r->id()]);
            if (!$s || !(int) $s['approved']) throw AppError::notFound();
            return self::storeView($s) + ['products' => array_map([self::class, 'productView'],
                $db()->all('SELECT * FROM products WHERE store_id=? AND available=1 ORDER BY category, name', [$r->id()]))];
        });

        App::route('POST', '/stores', function (Req $r) use ($db) {
            $b = $r->body();
            $city = $b->str('city', 2, 60);
            $id = Util::uuid();
            $db()->insert('stores', ['id' => $id, 'owner_id' => $r->uid(), 'kind' => $b->enum('kind', ['restaurant', 'shop']), 'name' => $b->str('name', 2, 80),
                                     'description' => $b->str('description', 0, 1000, ''), 'city' => $city, 'city_key' => Util::fold($city),
                                     'address' => $b->str('address', 0, 200, ''), 'delivery_fee_xaf' => $b->int('deliveryFeeXaf', 0, 100000, 0),
                                     'is_open' => 1, 'approved' => 0, 'created_at' => Util::now()]);
            $r->status = 201;
            return self::storeView((array) $db()->one('SELECT * FROM stores WHERE id=?', [$id]));
        }, $auth + ['limit' => [10, 60]]);

        App::route('PATCH', '/stores/{id}', function (Req $r) use ($db, $owned) {
            $b = $r->body();
            $b->only(['name', 'description', 'address', 'deliveryFeeXaf', 'isOpen']);
            $owned($r->id(), $r->uid());
            $set = [];
            if ($b->has('name')) $set['name'] = $b->str('name', 2, 80);
            if ($b->has('description')) $set['description'] = $b->str('description', 0, 1000);
            if ($b->has('address')) $set['address'] = $b->str('address', 0, 200);
            if ($b->has('deliveryFeeXaf')) $set['delivery_fee_xaf'] = $b->int('deliveryFeeXaf', 0, 100000);
            if ($b->has('isOpen')) $set['is_open'] = $b->bool('isOpen') ? 1 : 0;
            if (!$set) throw AppError::bad('empty_update');
            $db()->run('UPDATE stores SET ' . implode(', ', array_map(fn ($k) => "$k=?", array_keys($set))) . ' WHERE id=?', [...array_values($set), $r->id()]);
            return self::storeView((array) $db()->one('SELECT * FROM stores WHERE id=?', [$r->id()]));
        }, $auth);

        App::route('GET', '/stores/{id}/products/all', function (Req $r) use ($db, $owned) {
            $owned($r->id(), $r->uid());
            return ['items' => array_map([self::class, 'productView'], $db()->all('SELECT * FROM products WHERE store_id=? ORDER BY created_at DESC', [$r->id()]))];
        }, $auth);

        App::route('POST', '/stores/{id}/products', function (Req $r) use ($db, $owned) {
            $b = $r->body();
            $owned($r->id(), $r->uid());
            $id = Util::uuid();
            $db()->insert('products', ['id' => $id, 'store_id' => $r->id(), 'name' => $b->str('name', 2, 120), 'description' => $b->str('description', 0, 1000, ''),
                                       'category' => $b->str('category', 0, 60, ''), 'price_xaf' => $b->int('priceXaf', 1, 100000000),
                                       'stock' => $b->optInt('stock', 0, 1000000), 'available' => 1,
                                       'photo_url' => $b->has('photoUrl') ? In::photo($b->str('photoUrl', 1, 500)) : null, 'created_at' => Util::now()]);
            $r->status = 201;
            return self::productView((array) $db()->one('SELECT * FROM products WHERE id=?', [$id]));
        }, $auth);

        App::route('PATCH', '/products/{id}', function (Req $r) use ($db, $owned) {
            $b = $r->body();
            $b->only(['name', 'description', 'category', 'priceXaf', 'stock', 'photoUrl', 'available']);
            $p = $db()->one('SELECT store_id FROM products WHERE id=?', [$r->id()]);
            if (!$p) throw AppError::notFound();
            $owned((string) $p['store_id'], $r->uid());
            $set = [];
            $raw = json_decode($r->raw, true) ?: [];
            if ($b->has('name')) $set['name'] = $b->str('name', 2, 120);
            if ($b->has('description')) $set['description'] = $b->str('description', 0, 1000);
            if ($b->has('category')) $set['category'] = $b->str('category', 0, 60);
            if ($b->has('priceXaf')) $set['price_xaf'] = $b->int('priceXaf', 1, 100000000);
            if (array_key_exists('stock', $raw)) $set['stock'] = $b->optInt('stock', 0, 1000000); // null = illimité
            if ($b->has('photoUrl')) $set['photo_url'] = In::photo($b->str('photoUrl', 1, 500));
            if ($b->has('available')) $set['available'] = $b->bool('available') ? 1 : 0;
            if (!$set) throw AppError::bad('empty_update');
            $db()->run('UPDATE products SET ' . implode(', ', array_map(fn ($k) => "$k=?", array_keys($set))) . ' WHERE id=?', [...array_values($set), $r->id()]);
            return self::productView((array) $db()->one('SELECT * FROM products WHERE id=?', [$r->id()]));
        }, $auth);

        App::route('POST', '/stores/{id}/orders', function (Req $r) use ($db) {
            $want = [];
            foreach ($r->body()->arr('items', 1, 30) as $it) {
                $i = new In(is_array($it) ? $it : []);
                $pid = $i->uuid('productId');
                if (isset($want[$pid])) throw AppError::bad('duplicate_items');
                $want[$pid] = $i->int('qty', 1, 50);
            }
            $buyerId = $r->uid();
            $key = $r->idempotencyKey();
            if ($replay = Orders::findReplay($buyerId, $key)) return Orders::view($replay);
            $order = $db()->tx(function (Db $db) use ($r, $want, $buyerId, $key): array {
                $store = $db->one('SELECT owner_id, kind, approved, is_open, delivery_fee_xaf FROM stores WHERE id=?', [$r->id()]);
                if (!$store || !(int) $store['approved']) throw AppError::notFound('store_not_found');
                if (!(int) $store['is_open']) throw AppError::conflict('store_closed');
                $ids = array_keys($want);
                // Verrouille les produits dans un ordre stable (évite les interblocages).
                $rows = $db->all('SELECT id, name, price_xaf, stock, available FROM products WHERE store_id=? AND id IN (' . Db::marks($ids) . ') ORDER BY id' . $db->lock(),
                    [$r->id(), ...$ids]);
                if (count($rows) !== count($ids)) throw AppError::notFound('product_not_found');
                $items = [];
                $subtotal = 0;
                foreach ($rows as $p) {
                    $qty = $want[$p['id']];
                    if (!(int) $p['available']) throw AppError::conflict('product_unavailable');
                    if ($p['stock'] !== null && (int) $p['stock'] < $qty) throw AppError::conflict('out_of_stock');
                    if ($p['stock'] !== null) $db->run('UPDATE products SET stock = stock - ? WHERE id=?', [$qty, $p['id']]);
                    $items[] = ['productId' => $p['id'], 'name' => $p['name'], 'qty' => $qty, 'unitPriceXaf' => (int) $p['price_xaf']];
                    $subtotal += (int) $p['price_xaf'] * $qty;
                }
                $fee = (int) $store['delivery_fee_xaf'];
                if ($fee > 0) $items[] = ['name' => 'Livraison', 'qty' => 1, 'unitPriceXaf' => $fee];
                return Orders::insert($db, [
                    'buyerId' => $buyerId, 'sellerId' => (string) $store['owner_id'], 'kind' => $store['kind'] === 'restaurant' ? 'food' : 'shop',
                    'refId' => $r->id(), 'items' => $items, 'itemPriceXaf' => $subtotal + $fee, 'idempotencyKey' => $key,
                ]);
            });
            $r->status = 201;
            return Orders::view($order);
        }, $auth);

        App::route('GET', '/admin/stores', function () use ($db) {
            return ['items' => array_map([self::class, 'storeView'], $db()->all('SELECT * FROM stores WHERE approved=0 ORDER BY created_at LIMIT 200'))];
        }, $admin);

        App::route('POST', '/admin/stores/{id}/approve', function (Req $r) use ($db) {
            $s = $db()->one('SELECT owner_id, name FROM stores WHERE id=?', [$r->id()]);
            if (!$s) throw AppError::notFound();
            $db()->run('UPDATE stores SET approved=1 WHERE id=?', [$r->id()]);
            App::audit($r->uid(), 'store.approved', 'store', $r->id());
            App::notify((string) $s['owner_id'], 'Commerce validé', "« {$s['name']} » est maintenant visible dans l'app.", '/merchant', true);
            return ['id' => $r->id(), 'approved' => true];
        }, $admin);
    }
}
