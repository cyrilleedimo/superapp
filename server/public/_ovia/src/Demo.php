<?php
// Annonces d'exemple du lancement : elles rendent l'application vivante tant qu'il n'y a pas
// encore de vraies annonces. Elles portent la mention « Exemple », ne peuvent être commandées
// que par un administrateur (simulation), et disparaissent toutes seules dès que le nombre de
// vraies annonces atteint le seuil réglé (20 par défaut).
// Photos : Wikimedia Commons, licence CC0 (voir demo/SOURCES.md).
declare(strict_types=1);

namespace Ovia;

final class Demo
{
    /** Compte vendeur technique des exemples : sans e-mail ni téléphone, marqué suspendu — personne ne peut s'y connecter ni lui écrire. */
    public const SELLER_ID = '0d3a0000-0000-4000-8000-00000000e0e0';

    /** @return list<array<string,mixed>> */
    private static function items(): array
    {
        $j = json_decode((string) @file_get_contents(App::$root . '/demo/annonces.json'), true);
        return is_array($j) ? array_values(array_filter($j, 'is_array')) : [];
    }

    private static function listingId(string $key): string
    {
        $h = md5('ovia-exemple:' . $key);
        return sprintf('%s-%s-4%s-8%s-%s', substr($h, 0, 8), substr($h, 8, 4), substr($h, 13, 3), substr($h, 17, 3), substr($h, 20, 12));
    }

    private static function state(): string { return App::$settings->raw('demo.state') ?? ''; }

    /** Vraies annonces publiées à ce jour (hors exemples, hors annonces retirées). */
    private static function realCount(): int
    {
        return (int) App::$db->val("SELECT count(*) FROM listings WHERE is_demo=0 AND status <> 'removed'");
    }

    /** @return array<string,mixed> */
    public static function status(): array
    {
        return [
            'state' => self::state(), 'enabled' => App::$settings->bool('demo.enabled'),
            'active' => (int) App::$db->val("SELECT count(*) FROM listings WHERE is_demo=1 AND status='active'"),
            'available' => count(self::items()), 'realListings' => self::realCount(), 'removeAfter' => App::$settings->int('demo.remove_after'),
        ];
    }

    /** Appelé par les tâches de fond : installe petit à petit, puis retire quand le seuil est atteint. */
    public static function tick(): void
    {
        if (getenv('OVIA_NO_DEMO')) return; // tests automatisés
        $state = self::state();
        if ($state === 'removed') return;
        $threshold = App::$settings->int('demo.remove_after');
        if (!App::$settings->bool('demo.enabled') || ($threshold > 0 && self::realCount() >= $threshold)) {
            if ($state !== '') self::remove(); else App::$settings->set('demo.state', 'removed', false);
            return;
        }
        if ($state === '' || $state === 'installing') self::install(3);
    }

    /** Crée jusqu'à $max annonces d'exemple manquantes. */
    public static function install(int $max): void
    {
        $db = App::$db;
        $items = self::items();
        if (!$items) return;
        if (!$db->one('SELECT id FROM users WHERE id=?', [self::SELLER_ID])) {
            $db->insertIgnore('users', [
                'id' => self::SELLER_ID, 'email' => null, 'phone' => null, 'display_name' => 'Exemples Ovia',
                'password_hash' => '!', 'status' => 'suspended', 'role' => 'user', 'email_verified' => 0, 'failed_logins' => 0,
                'locked_until' => null, 'created_at' => Util::now(), 'updated_at' => Util::now(),
            ]);
        }
        App::$settings->set('demo.state', 'installing', false);
        $done = 0;
        $missing = 0;
        foreach ($items as $i => $it) {
            $id = self::listingId((string) $it['key']);
            $row = $db->one('SELECT status FROM listings WHERE id=?', [$id]);
            if ($row) {
                if ($row['status'] === 'removed') $db->run("UPDATE listings SET status='active', updated_at=? WHERE id=?", [Util::now(), $id]);
                continue;
            }
            if ($done >= $max) { $missing++; continue; }
            $done++;
            $photo = (string) $it['image'];
            try {
                // La photo est livrée avec le serveur ; sinon on la télécharge ; à défaut, on garde l'adresse d'origine.
                $local = App::$root . '/demo/img/' . preg_replace('/[^a-z0-9-]/', '', (string) $it['key']) . '.img';
                $raw = is_file($local) ? (string) file_get_contents($local) : null;
                if ($raw === null) {
                    $res = Http::request('GET', $photo, ['User-Agent' => 'OviaDemo/1.0 (' . App::publicUrl() . ')'], null, 20);
                    if ($res['status'] === 200 && $res['body'] !== '') $raw = $res['body'];
                }
                if ($raw !== null) $photo = '/media/' . Market::storeImage($raw, self::SELLER_ID);
            } catch (\Throwable $e) {
                error_log('Ovia exemples : image non copiée (' . $e->getMessage() . ')');
            }
            $title = Util::clip((string) $it['title'], 120);
            $desc = Util::clip((string) $it['description'], 4000);
            $city = (string) $it['city'];
            $db->insertIgnore('listings', [
                'id' => $id, 'seller_id' => self::SELLER_ID, 'title' => $title, 'description' => $desc, 'category' => (string) $it['category'],
                'item_condition' => (string) $it['condition'], 'price_xaf' => (int) $it['priceXaf'], 'city' => $city, 'city_key' => Util::fold($city),
                'photos' => (string) json_encode([$photo]), 'search_text' => Util::fold("$title $desc"), 'status' => 'active',
                // Dates étalées pour un fil d'actualité naturel.
                'created_at' => Util::now(-($i * 5400 + 600)), 'updated_at' => Util::now(), 'is_demo' => 1,
            ]);
        }
        if ($missing === 0) App::$settings->set('demo.state', 'installed', false);
    }

    /** Retire les exemples encore en ligne et supprime leurs photos. Les exemples déjà commandés restent dans l'historique. */
    public static function remove(): void
    {
        $db = App::$db;
        foreach ($db->all("SELECT id, photos FROM listings WHERE is_demo=1 AND status='active'") as $l) {
            foreach (json_decode((string) $l['photos'], true) ?: [] as $url) {
                if (!is_string($url) || !preg_match('#^/media/(' . trim(In::UUID, '/^$') . ')$#', $url, $m)) continue;
                $media = $db->one('SELECT storage_key FROM media WHERE id=? AND owner_id=?', [$m[1], self::SELLER_ID]);
                if ($media) {
                    @unlink(App::$dataDir . '/uploads/' . $media['storage_key']);
                    $db->run('DELETE FROM media WHERE id=?', [$m[1]]);
                }
            }
            $db->run("UPDATE listings SET status='removed', updated_at=? WHERE id=?", [Util::now(), $l['id']]);
        }
        App::$settings->set('demo.state', 'removed', false);
    }
}
