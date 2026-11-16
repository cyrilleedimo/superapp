<?php
// Messagerie : discussions acheteur ↔ vendeur autour d'une annonce (avec offres de prix),
// discussions privées entre deux personnes et groupes (jusqu'à 50 membres).
// Les messages sont chiffrés sur le serveur (au repos) et voyagent en HTTPS. Ils restent
// lisibles par l'équipe en cas de litige ou de signalement : ce n'est PAS du chiffrement
// de bout en bout, choix assumé pour pouvoir arbitrer les ventes et bloquer les arnaques.
declare(strict_types=1);

namespace Ovia;

final class Messaging
{
    private const GROUP_MAX = 50;

    private static function seal(string $text): string { return Crypto::seal($text, (string) App::$config['data_key']); }

    private static function open(?string $sealed): string
    {
        if ($sealed === null || $sealed === '') return '';
        return Crypto::open($sealed, (string) App::$config['data_key']) ?? '';
    }

    /** Vérifie l'appartenance et renvoie la conversation. @return array<string,mixed> */
    private static function member(string $convId, string $userId): array
    {
        $c = App::$db->one('SELECT c.*, m.role AS my_role, m.last_read_id FROM conversations c
                            JOIN conversation_members m ON m.conversation_id = c.id AND m.user_id = ? WHERE c.id=?', [$userId, $convId]);
        if (!$c) throw AppError::notFound();
        return $c;
    }

    /** @return list<string> */
    private static function memberIds(string $convId): array
    {
        return array_column(App::$db->all('SELECT user_id FROM conversation_members WHERE conversation_id=?', [$convId]), 'user_id');
    }

    private static function addMember(Db $db, string $convId, string $userId, string $role = 'member'): void
    {
        $db->insertIgnore('conversation_members', ['conversation_id' => $convId, 'user_id' => $userId, 'role' => $role, 'last_read_id' => 0, 'joined_at' => Util::now()]);
    }

    private static function post(Db $db, string $convId, string $senderId, string $body, string $kind = 'text', ?string $mediaId = null, ?string $offerId = null): int
    {
        $db->insert('messages', ['conversation_id' => $convId, 'sender_id' => $senderId, 'kind' => $kind, 'body' => self::seal($body),
                                 'media_id' => $mediaId, 'offer_id' => $offerId, 'created_at' => Util::now()]);
        $id = $db->lastId();
        $db->run('UPDATE conversations SET last_message_at=? WHERE id=?', [Util::now(), $convId]);
        $db->run('UPDATE conversation_members SET last_read_id=? WHERE conversation_id=? AND user_id=?', [$id, $convId, $senderId]);
        return $id;
    }

    public static function routes(): void
    {
        $auth = ['auth' => true];
        $db = fn (): Db => App::$db;

        // Trouver quelqu'un à qui écrire : e-mail ou numéro exact, ou début du nom (3 lettres minimum).
        App::route('GET', '/users/search', function (Req $r) use ($db) {
            $q = $r->query()->str('q', 3, 190);
            $uid = $r->uid();
            $phone = preg_replace('/[\s().-]/', '', $q) ?? '';
            if (str_contains($q, '@')) {
                $rows = $db()->all("SELECT id, display_name FROM users WHERE email=? AND status='active' AND id<>? LIMIT 5", [mb_strtolower($q), $uid]);
            } elseif (preg_match(In::PHONE, $phone)) {
                $rows = $db()->all("SELECT id, display_name FROM users WHERE phone=? AND status='active' AND id<>? LIMIT 5", [$phone, $uid]);
            } else {
                $like = '%' . str_replace(['!', '%', '_'], ['!!', '!%', '!_'], mb_strtolower($q)) . '%';
                $rows = $db()->all("SELECT id, display_name FROM users WHERE lower(display_name) LIKE ? ESCAPE '!' AND status='active' AND id<>? ORDER BY display_name LIMIT 10", [$like, $uid]);
            }
            return ['items' => array_map(fn ($u) => ['id' => $u['id'], 'displayName' => $u['display_name']], $rows)];
        }, $auth + ['limit' => [30, 60]]);

        // Ouvre (ou retrouve) la conversation de l'acheteur sur une annonce.
        App::route('POST', '/conversations', function (Req $r) use ($db) {
            $listingId = $r->body()->uuid('listingId');
            $uid = $r->uid();
            $l = $db()->one('SELECT seller_id, status, is_demo FROM listings WHERE id=?', [$listingId]);
            if (!$l || $l['status'] === 'removed') throw AppError::notFound('listing_not_found');
            if ((int) $l['is_demo'] && ($r->user['role'] ?? '') !== 'admin') throw AppError::forbidden('demo_listing');
            if ($l['seller_id'] === $uid) throw AppError::forbidden('own_listing');
            $id = $db()->tx(function (Db $db) use ($listingId, $uid, $l): string {
                $c = $db->one('SELECT id FROM conversations WHERE listing_id=? AND buyer_id=?', [$listingId, $uid]);
                if ($c) return (string) $c['id'];
                $id = Util::uuid();
                $db->insert('conversations', ['id' => $id, 'kind' => 'listing', 'title' => null, 'listing_id' => $listingId, 'buyer_id' => $uid,
                                              'seller_id' => $l['seller_id'], 'direct_key' => null, 'created_by' => $uid,
                                              'last_message_at' => Util::now(), 'created_at' => Util::now()]);
                self::addMember($db, $id, $uid);
                self::addMember($db, $id, (string) $l['seller_id']);
                return $id;
            });
            $r->status = 201;
            return ['id' => $id];
        }, $auth);

        // Discussion privée entre deux personnes.
        App::route('POST', '/conversations/direct', function (Req $r) use ($db) {
            $other = $r->body()->uuid('userId');
            $uid = $r->uid();
            if ($other === $uid) throw AppError::bad('validation_failed', 'userId');
            if (!$db()->one("SELECT id FROM users WHERE id=? AND status='active'", [$other])) throw AppError::notFound('user_not_found');
            $pair = [$uid, $other];
            sort($pair);
            $key = implode('|', $pair);
            $id = $db()->tx(function (Db $db) use ($key, $uid, $other): string {
                $c = $db->one('SELECT id FROM conversations WHERE direct_key=?', [$key]);
                if ($c) return (string) $c['id'];
                $id = Util::uuid();
                $db->insert('conversations', ['id' => $id, 'kind' => 'direct', 'title' => null, 'listing_id' => null, 'buyer_id' => null, 'seller_id' => null,
                                              'direct_key' => $key, 'created_by' => $uid, 'last_message_at' => Util::now(), 'created_at' => Util::now()]);
                self::addMember($db, $id, $uid);
                self::addMember($db, $id, $other);
                return $id;
            });
            $r->status = 201;
            return ['id' => $id];
        }, $auth + ['limit' => [20, 60]]);

        // Créer un groupe.
        App::route('POST', '/groups', function (Req $r) use ($db) {
            $b = $r->body();
            $title = $b->str('title', 2, 80);
            $uid = $r->uid();
            $ids = array_values(array_unique(array_filter($b->arr('memberIds', 1, self::GROUP_MAX - 1), fn ($v) => is_string($v) && preg_match(In::UUID, $v) && $v !== $uid)));
            if (!$ids) throw AppError::bad('validation_failed', 'memberIds');
            $valid = array_column($db()->all('SELECT id FROM users WHERE id IN (' . Db::marks($ids) . ") AND status='active'", $ids), 'id');
            if (!$valid) throw AppError::notFound('user_not_found');
            $me = (string) $db()->val('SELECT display_name FROM users WHERE id=?', [$uid]);
            $id = $db()->tx(function (Db $db) use ($title, $uid, $valid, $me): string {
                $id = Util::uuid();
                $db->insert('conversations', ['id' => $id, 'kind' => 'group', 'title' => $title, 'listing_id' => null, 'buyer_id' => null, 'seller_id' => null,
                                              'direct_key' => null, 'created_by' => $uid, 'last_message_at' => Util::now(), 'created_at' => Util::now()]);
                self::addMember($db, $id, $uid, 'admin');
                foreach ($valid as $m) self::addMember($db, $id, (string) $m);
                self::post($db, $id, $uid, "$me a créé le groupe « $title »", 'system');
                foreach ($valid as $m) App::notify((string) $m, 'Nouveau groupe', "$me t'a ajouté au groupe « $title ».", "/chat/$id");
                return $id;
            });
            $r->status = 201;
            return ['id' => $id];
        }, $auth + ['limit' => [10, 60]]);

        App::route('PATCH', '/groups/{id}', function (Req $r) use ($db) {
            $title = $r->body()->str('title', 2, 80);
            $c = self::member($r->id(), $r->uid());
            if ($c['kind'] !== 'group' || $c['my_role'] !== 'admin') throw AppError::forbidden();
            $db()->run('UPDATE conversations SET title=? WHERE id=?', [$title, $c['id']]);
            return ['id' => $c['id'], 'title' => $title];
        }, $auth);

        App::route('POST', '/groups/{id}/members', function (Req $r) use ($db) {
            $userId = $r->body()->uuid('userId');
            $c = self::member($r->id(), $r->uid());
            if ($c['kind'] !== 'group' || $c['my_role'] !== 'admin') throw AppError::forbidden();
            $u = $db()->one("SELECT display_name FROM users WHERE id=? AND status='active'", [$userId]);
            if (!$u) throw AppError::notFound('user_not_found');
            if (count(self::memberIds((string) $c['id'])) >= self::GROUP_MAX) throw AppError::conflict('group_full');
            $db()->tx(function (Db $db) use ($c, $userId, $u, $r): void {
                if ($db->one('SELECT user_id FROM conversation_members WHERE conversation_id=? AND user_id=?', [$c['id'], $userId])) return;
                self::addMember($db, (string) $c['id'], $userId);
                self::post($db, (string) $c['id'], $r->uid(), "{$u['display_name']} a rejoint le groupe", 'system');
                App::notify($userId, 'Nouveau groupe', "Tu as été ajouté au groupe « {$c['title']} ».", "/chat/{$c['id']}");
            });
            return ['ok' => true];
        }, $auth);

        App::route('POST', '/groups/{id}/leave', function (Req $r) use ($db) {
            $uid = $r->uid();
            $c = self::member($r->id(), $uid);
            if ($c['kind'] !== 'group') throw AppError::forbidden();
            $me = (string) $db()->val('SELECT display_name FROM users WHERE id=?', [$uid]);
            $db()->tx(function (Db $db) use ($c, $uid, $me): void {
                self::post($db, (string) $c['id'], $uid, "$me a quitté le groupe", 'system');
                $db->run('DELETE FROM conversation_members WHERE conversation_id=? AND user_id=?', [$c['id'], $uid]);
                // Le groupe garde toujours un responsable.
                if ($c['my_role'] === 'admin' && !$db->one("SELECT user_id FROM conversation_members WHERE conversation_id=? AND role='admin'", [$c['id']])) {
                    $next = $db->one('SELECT user_id FROM conversation_members WHERE conversation_id=? ORDER BY joined_at LIMIT 1', [$c['id']]);
                    if ($next) $db->run("UPDATE conversation_members SET role='admin' WHERE conversation_id=? AND user_id=?", [$c['id'], $next['user_id']]);
                }
            });
            return null;
        }, $auth);

        App::route('GET', '/conversations', function (Req $r) use ($db) {
            $uid = $r->uid();
            $rows = $db()->all(
                "SELECT c.id, c.kind, c.title, c.listing_id, c.buyer_id, c.seller_id, c.last_message_at, m.last_read_id,
                        l.title AS listing_title, l.price_xaf AS listing_price,
                        (SELECT count(*) FROM conversation_members x WHERE x.conversation_id = c.id) AS member_count,
                        (SELECT count(*) FROM messages g WHERE g.conversation_id = c.id AND g.id > m.last_read_id AND g.sender_id <> ?) AS unread,
                        (SELECT g.body FROM messages g WHERE g.conversation_id = c.id ORDER BY g.id DESC LIMIT 1) AS last_body,
                        (SELECT u.display_name FROM conversation_members x JOIN users u ON u.id = x.user_id
                          WHERE x.conversation_id = c.id AND x.user_id <> ? ORDER BY x.joined_at LIMIT 1) AS other_name
                 FROM conversations c JOIN conversation_members m ON m.conversation_id = c.id AND m.user_id = ?
                 LEFT JOIN listings l ON l.id = c.listing_id
                 ORDER BY c.last_message_at DESC LIMIT 100", [$uid, $uid, $uid]);
            return ['items' => array_map(fn ($c) => [
                'id' => $c['id'], 'kind' => $c['kind'],
                'title' => $c['kind'] === 'group' ? $c['title'] : ($c['other_name'] ?? 'Conversation'),
                'otherName' => $c['kind'] === 'group' ? $c['title'] : ($c['other_name'] ?? '?'),
                'listingId' => $c['listing_id'], 'listingTitle' => $c['listing_title'],
                'listingPriceXaf' => $c['listing_price'] === null ? null : (int) $c['listing_price'],
                'iAmBuyer' => $c['buyer_id'] === $uid, 'memberCount' => (int) $c['member_count'], 'unread' => (int) $c['unread'],
                'lastMessageAt' => Util::iso((string) $c['last_message_at']),
                'lastMessage' => $c['last_body'] === null ? null : Util::clip(self::open((string) $c['last_body']), 140),
            ], $rows)];
        }, $auth);

        App::route('GET', '/messages/unread', function (Req $r) use ($db) {
            $uid = $r->uid();
            return ['unread' => (int) $db()->val(
                'SELECT count(*) FROM messages g JOIN conversation_members m ON m.conversation_id = g.conversation_id AND m.user_id = ?
                 WHERE g.id > m.last_read_id AND g.sender_id <> ?', [$uid, $uid])];
        }, $auth + ['limit' => [120, 60]]);

        App::route('GET', '/conversations/{id}', function (Req $r) use ($db) {
            $uid = $r->uid();
            $c = self::member($r->id(), $uid);
            $members = $db()->all('SELECT u.id, u.display_name, m.role FROM conversation_members m JOIN users u ON u.id = m.user_id
                                   WHERE m.conversation_id=? ORDER BY m.joined_at', [$c['id']]);
            $l = $c['listing_id'] ? $db()->one('SELECT title, price_xaf FROM listings WHERE id=?', [$c['listing_id']]) : null;
            $others = array_values(array_filter($members, fn ($m) => $m['id'] !== $uid));
            return [
                'id' => $c['id'], 'kind' => $c['kind'], 'myRole' => $c['my_role'],
                'title' => $c['kind'] === 'group' ? $c['title'] : ($others[0]['display_name'] ?? 'Conversation'),
                'otherName' => $c['kind'] === 'group' ? $c['title'] : ($others[0]['display_name'] ?? '?'),
                'listingId' => $c['listing_id'], 'listingTitle' => $l['title'] ?? null,
                'listingPriceXaf' => $l ? (int) $l['price_xaf'] : null, 'iAmBuyer' => $c['buyer_id'] === $uid,
                'members' => array_map(fn ($m) => ['id' => $m['id'], 'displayName' => $m['display_name'], 'role' => $m['role']], $members),
            ];
        }, $auth);

        App::route('GET', '/conversations/{id}/messages', function (Req $r) use ($db) {
            $uid = $r->uid();
            $after = $r->query()->int('after', 0, PHP_INT_MAX, 0);
            $c = self::member($r->id(), $uid);
            $rows = $db()->all(
                'SELECT g.id, g.sender_id, g.kind, g.body, g.media_id, g.created_at, u.display_name AS sender_name,
                        o.id AS o_id, o.amount_xaf AS o_amount, o.status AS o_status
                 FROM messages g JOIN users u ON u.id = g.sender_id LEFT JOIN offers o ON o.id = g.offer_id
                 WHERE g.conversation_id=? AND g.id > ? ORDER BY g.id LIMIT 200', [$c['id'], $after]);
            if ($rows) {
                $last = (int) end($rows)['id'];
                if ($last > (int) $c['last_read_id']) {
                    $db()->run('UPDATE conversation_members SET last_read_id=? WHERE conversation_id=? AND user_id=?', [$last, $c['id'], $uid]);
                }
            }
            return ['items' => array_map(fn ($g) => [
                'id' => (int) $g['id'], 'senderId' => $g['sender_id'], 'senderName' => $g['sender_name'], 'kind' => $g['kind'],
                'body' => self::open((string) $g['body']), 'mediaUrl' => $g['media_id'] ? "/media/{$g['media_id']}" : null,
                'createdAt' => Util::iso((string) $g['created_at']),
                'offer' => $g['o_id'] ? ['id' => $g['o_id'], 'amountXaf' => (int) $g['o_amount'], 'status' => $g['o_status']] : null,
            ], $rows)];
        }, $auth + ['limit' => [240, 60]]);

        App::route('POST', '/conversations/{id}/messages', function (Req $r) use ($db) {
            $b = $r->body();
            $mediaId = $b->optUuid('mediaId');
            $body = $b->str('body', $mediaId ? 0 : 1, 2000, $mediaId ? '' : null);
            $uid = $r->uid();
            $c = self::member($r->id(), $uid);
            if ($mediaId && !$db()->one('SELECT id FROM media WHERE id=? AND owner_id=?', [$mediaId, $uid])) throw AppError::notFound('photos_not_found');
            $me = (string) $db()->val('SELECT display_name FROM users WHERE id=?', [$uid]);
            $id = $db()->tx(function (Db $db) use ($c, $uid, $body, $mediaId, $me): int {
                $id = self::post($db, (string) $c['id'], $uid, $body, 'text', $mediaId);
                $preview = $body !== '' ? Util::clip($body, 120) : 'Photo';
                $title = $c['kind'] === 'group' ? "{$c['title']} · $me" : "Message de $me";
                foreach (self::memberIds((string) $c['id']) as $m) {
                    if ($m !== $uid) App::notify($m, $title, $preview, "/chat/{$c['id']}");
                }
                return $id;
            });
            $r->status = 201;
            return ['id' => $id];
        }, $auth + ['limit' => [60, 60]]);

        // L'acheteur propose un prix.
        App::route('POST', '/conversations/{id}/offers', function (Req $r) use ($db) {
            $amount = $r->body()->int('amountXaf', 1, 100000000);
            $uid = $r->uid();
            $c = self::member($r->id(), $uid);
            if ($c['kind'] !== 'listing' || $c['buyer_id'] !== $uid) throw AppError::forbidden('only_buyer_can_offer');
            $offerId = $db()->tx(function (Db $db) use ($c, $uid, $amount): string {
                $l = $db->one('SELECT price_xaf, status FROM listings WHERE id=?', [$c['listing_id']]);
                if (!$l || $l['status'] !== 'active') throw AppError::conflict('listing_unavailable');
                if ($amount >= (int) $l['price_xaf']) throw AppError::conflict('offer_not_below_price');
                $db->run("UPDATE offers SET status='declined', decided_at=? WHERE conversation_id=? AND status='pending'", [Util::now(), $c['id']]);
                $id = Util::uuid();
                $db->insert('offers', ['id' => $id, 'conversation_id' => $c['id'], 'amount_xaf' => $amount, 'status' => 'pending', 'created_at' => Util::now(), 'decided_at' => null]);
                self::post($db, (string) $c['id'], $uid, "Offre : $amount FCFA", 'text', null, $id);
                App::notify((string) $c['seller_id'], 'Nouvelle offre', "Offre de $amount FCFA sur ton article.", "/chat/{$c['id']}");
                return $id;
            });
            $r->status = 201;
            return ['id' => $offerId];
        }, $auth);

        // Le vendeur accepte ou refuse.
        App::route('POST', '/offers/{id}/decision', function (Req $r) use ($db) {
            $accept = $r->body()->bool('accept');
            $uid = $r->uid();
            return $db()->tx(function (Db $db) use ($r, $uid, $accept): array {
                $o = $db->one('SELECT f.status, f.conversation_id, f.amount_xaf, c.seller_id, c.buyer_id FROM offers f
                               JOIN conversations c ON c.id = f.conversation_id WHERE f.id=?' . $db->lock(), [$r->id()]);
                if (!$o || $o['seller_id'] !== $uid) throw AppError::notFound();
                if ($o['status'] !== 'pending') throw AppError::conflict('offer_already_decided');
                $status = $accept ? 'accepted' : 'declined';
                $db->run('UPDATE offers SET status=?, decided_at=? WHERE id=?', [$status, Util::now(), $r->id()]);
                self::post($db, (string) $o['conversation_id'], $uid, $accept ? "Offre de {$o['amount_xaf']} FCFA acceptée" : 'Offre refusée');
                App::notify((string) $o['buyer_id'], $accept ? 'Offre acceptée' : 'Offre refusée',
                    $accept ? "Tu peux acheter pour {$o['amount_xaf']} FCFA." : 'Le vendeur a refusé ton offre.', "/chat/{$o['conversation_id']}");
                return ['id' => $r->id(), 'status' => $status];
            });
        }, $auth);
    }
}
