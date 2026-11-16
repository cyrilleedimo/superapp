<?php
// Seconde main : annonces (recherche, pagination par curseur), photos (vérifiées et
// ré-encodées côté serveur) et assistant « Décrire avec l'IA ».
declare(strict_types=1);

namespace Ovia;

final class Market
{
    public const CATEGORIES = ['women', 'men', 'kids', 'electronics', 'home', 'beauty', 'sports', 'other'];
    private const CONDITIONS = ['new', 'very_good', 'good', 'fair'];
    private const MAX_BYTES = 5242880;
    private const MAX_SIDE = 1600;
    private const MAX_PIXELS = 20000000;

    /** @param array<string,mixed> $l */
    private static function view(array $l): array
    {
        return [
            'id' => $l['id'], 'sellerId' => $l['seller_id'], 'title' => $l['title'], 'description' => $l['description'],
            'category' => $l['category'], 'condition' => $l['item_condition'], 'priceXaf' => (int) $l['price_xaf'], 'city' => $l['city'],
            'photos' => json_decode((string) $l['photos'], true) ?: [], 'status' => $l['status'], 'createdAt' => Util::iso((string) $l['created_at']),
        ];
    }

    /** @return list<string> */
    private static function photos(In $b): array
    {
        return array_map([In::class, 'photo'], $b->arr('photos', 0, 10));
    }

    public static function routes(): void
    {
        $auth = ['auth' => true];
        $db = fn (): Db => App::$db;

        App::route('GET', '/listings', function (Req $r) use ($db) {
            $q = $r->query();
            $limit = $q->int('limit', 1, 50, 20);
            $where = ["status = 'active'"];
            $args = [];
            if ($text = $q->optStr('q', 1, 100)) {
                foreach (array_slice(array_filter(explode(' ', Util::fold($text)), fn ($w) => mb_strlen($w) >= 2), 0, 6) as $word) {
                    $where[] = "search_text LIKE ? ESCAPE '!'";
                    $args[] = '%' . str_replace(['!', '%', '_'], ['!!', '!%', '!_'], $word) . '%';
                }
            }
            if ($q->has('category')) { $where[] = 'category = ?'; $args[] = $q->enum('category', self::CATEGORIES); }
            if ($city = $q->optStr('city', 1, 60)) { $where[] = 'city_key = ?'; $args[] = Util::fold($city); }
            if (($min = $q->optInt('minPrice', 0, 1000000000)) !== null) { $where[] = 'price_xaf >= ?'; $args[] = $min; }
            if (($max = $q->optInt('maxPrice', 0, 1000000000)) !== null) { $where[] = 'price_xaf <= ?'; $args[] = $max; }
            if ($cursor = $q->optStr('cursor', 1, 200)) {
                // Curseur opaque = base64url("<created_at>|<id>")
                $parts = explode('|', (string) Util::b64uDecode($cursor));
                if (count($parts) !== 2 || !preg_match('/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/', $parts[0]) || !preg_match(In::UUID, $parts[1])) throw AppError::bad('invalid_cursor');
                $where[] = '(created_at < ? OR (created_at = ? AND id < ?))';
                array_push($args, $parts[0], $parts[0], $parts[1]);
            }
            $args[] = $limit + 1;
            $rows = $db()->all('SELECT * FROM listings WHERE ' . implode(' AND ', $where) . ' ORDER BY created_at DESC, id DESC LIMIT ?', $args);
            $items = array_slice($rows, 0, $limit);
            $last = end($items);
            return [
                'items' => array_map([self::class, 'view'], $items),
                'nextCursor' => count($rows) > $limit && $last ? Util::b64u(substr((string) $last['created_at'], 0, 19) . '|' . $last['id']) : null,
            ];
        });

        App::route('GET', '/listings/mine', function (Req $r) use ($db) {
            return ['items' => array_map([self::class, 'view'],
                $db()->all("SELECT * FROM listings WHERE seller_id=? AND status <> 'removed' ORDER BY created_at DESC LIMIT 100", [$r->uid()]))];
        }, $auth);

        App::route('GET', '/listings/{id}', function (Req $r) use ($db) {
            $l = $db()->one("SELECT l.*, u.display_name AS seller_name FROM listings l JOIN users u ON u.id = l.seller_id WHERE l.id=? AND l.status <> 'removed'", [$r->id()]);
            if (!$l) throw AppError::notFound();
            return self::view($l) + ['seller' => ['id' => $l['seller_id'], 'displayName' => $l['seller_name']]];
        });

        App::route('POST', '/listings', function (Req $r) use ($db) {
            $b = $r->body();
            $title = $b->str('title', 3, 120);
            $desc = $b->str('description', 0, 4000, '');
            $city = $b->str('city', 2, 60);
            $id = Util::uuid();
            $db()->insert('listings', [
                'id' => $id, 'seller_id' => $r->uid(), 'title' => $title, 'description' => $desc,
                'category' => $b->enum('category', self::CATEGORIES), 'item_condition' => $b->enum('condition', self::CONDITIONS),
                'price_xaf' => $b->int('priceXaf', 1, 100000000), 'city' => $city, 'city_key' => Util::fold($city),
                'photos' => (string) json_encode(self::photos($b)), 'search_text' => Util::fold("$title $desc"), 'status' => 'active',
                'created_at' => Util::now(), 'updated_at' => Util::now(),
            ]);
            App::audit($r->uid(), 'listing.create', 'listing', $id);
            $r->status = 201;
            return self::view((array) $db()->one('SELECT * FROM listings WHERE id=?', [$id]));
        }, $auth + ['limit' => [20, 60]]);

        App::route('PATCH', '/listings/{id}', function (Req $r) use ($db) {
            $b = $r->body();
            $b->only(['title', 'description', 'category', 'condition', 'priceXaf', 'city', 'photos']);
            $row = $db()->one('SELECT * FROM listings WHERE id=?', [$r->id()]);
            if (!$row) throw AppError::notFound();
            if ($row['seller_id'] !== $r->uid()) throw AppError::forbidden();
            // Une annonce réservée ou vendue ne change plus de prix (protège l'acheteur).
            if ($row['status'] !== 'active') throw AppError::bad('listing_locked');
            $set = [];
            if ($b->has('title')) $set['title'] = $b->str('title', 3, 120);
            if ($b->has('description')) $set['description'] = $b->str('description', 0, 4000);
            if ($b->has('category')) $set['category'] = $b->enum('category', self::CATEGORIES);
            if ($b->has('condition')) $set['item_condition'] = $b->enum('condition', self::CONDITIONS);
            if ($b->has('priceXaf')) $set['price_xaf'] = $b->int('priceXaf', 1, 100000000);
            if ($b->has('city')) { $set['city'] = $b->str('city', 2, 60); $set['city_key'] = Util::fold($set['city']); }
            if ($b->has('photos')) $set['photos'] = (string) json_encode(self::photos($b));
            if (!$set) throw AppError::bad('empty_update');
            $set['search_text'] = Util::fold(($set['title'] ?? $row['title']) . ' ' . ($set['description'] ?? $row['description']));
            $set['updated_at'] = Util::now();
            $db()->run('UPDATE listings SET ' . implode(', ', array_map(fn ($k) => "$k=?", array_keys($set))) . ' WHERE id=?', [...array_values($set), $r->id()]);
            return self::view((array) $db()->one('SELECT * FROM listings WHERE id=?', [$r->id()]));
        }, $auth);

        App::route('DELETE', '/listings/{id}', function (Req $r) use ($db) {
            if (!$db()->run("UPDATE listings SET status='removed', updated_at=? WHERE id=? AND seller_id=? AND status='active'", [Util::now(), $r->id(), $r->uid()])) {
                throw AppError::notFound();
            }
            return null;
        }, $auth);

        // ------------------------------------------------------------- Photos
        App::route('POST', '/media', function (Req $r) use ($db) {
            $raw = $r->raw;
            if ($raw === '' || strlen($raw) > self::MAX_BYTES) throw new AppError(strlen($raw) > self::MAX_BYTES ? 413 : 415, 'unsupported_image');
            [$data, $mime, $ext] = self::reencode($raw);
            $key = Util::token(18) . '.' . $ext;
            if (file_put_contents(App::$dataDir . '/uploads/' . $key, $data, LOCK_EX) === false) throw new \RuntimeException('écriture du média impossible');
            $id = Util::uuid();
            $db()->insert('media', ['id' => $id, 'owner_id' => $r->uid(), 'mime' => $mime, 'bytes' => strlen($data), 'sha256' => hash('sha256', $data),
                                    'storage_key' => $key, 'created_at' => Util::now()]);
            $r->status = 201;
            // Chemin relatif : l'application le complète avec l'adresse du serveur qu'elle utilise déjà.
            return ['id' => $id, 'url' => "/media/$id"];
        }, $auth + ['limit' => [30, 60]]);

        App::route('GET', '/media/{id}', function (Req $r) use ($db) {
            $m = $db()->one('SELECT storage_key, mime FROM media WHERE id=?', [$r->id()]);
            if (!$m || !preg_match('/^[A-Za-z0-9_-]+\.(webp|jpg|png)$/', (string) $m['storage_key'])) throw AppError::notFound();
            $data = @file_get_contents(App::$dataDir . '/uploads/' . $m['storage_key']);
            if ($data === false) throw AppError::notFound();
            return new RawResponse($data, (string) $m['mime'], ['Cache-Control' => 'public, max-age=31536000, immutable', 'Content-Length' => (string) strlen($data)]);
        }, ['limit' => [600, 60]]);

        // ---------------------------------------------- Assistant de description
        App::route('POST', '/listings/suggest-description', function (Req $r) use ($db) {
            $key = App::$settings->str('gemini.api_key');
            if ($key === '') throw new AppError(503, 'ai_not_configured');
            $ids = array_map(function ($v) {
                if (!is_string($v) || !preg_match(In::UUID, $v)) throw AppError::bad('validation_failed', 'photoIds');
                return $v;
            }, $r->body()->arr('photoIds', 1, 5));
            $rows = $db()->all('SELECT storage_key, mime FROM media WHERE id IN (' . Db::marks($ids) . ') AND owner_id=?', [...$ids, $r->uid()]);
            if (!$rows) throw AppError::notFound('photos_not_found');
            $images = [];
            foreach ($rows as $row) {
                $data = @file_get_contents(App::$dataDir . '/uploads/' . $row['storage_key']);
                if ($data !== false) $images[] = ['inline_data' => ['mime_type' => $row['mime'], 'data' => base64_encode($data)]];
            }
            if (!$images) throw AppError::notFound('photos_not_found');
            try {
                return self::suggest($key, $images);
            } catch (\Throwable $e) {
                error_log('Ovia IA : ' . $e->getMessage());
                throw new AppError(502, 'ai_unavailable', $e->getMessage());
            }
        }, $auth + ['limit' => [10, 60]]);
    }

    /**
     * Vérifie que c'est une vraie image et la ré-encode (supprime EXIF/GPS et tout contenu caché).
     * @return array{0:string,1:string,2:string} [octets, type MIME, extension]
     */
    private static function reencode(string $raw): array
    {
        $kind = str_starts_with($raw, "\xff\xd8\xff") ? 'jpg'
            : (str_starts_with($raw, "\x89PNG\r\n\x1a\n") ? 'png'
            : (substr($raw, 0, 4) === 'RIFF' && substr($raw, 8, 4) === 'WEBP' ? 'webp' : null));
        if ($kind === null) throw new AppError(415, 'unsupported_image');
        $info = @getimagesizefromstring($raw);
        if (!$info || $info[0] < 1 || $info[1] < 1 || $info[0] * $info[1] > self::MAX_PIXELS) throw new AppError(415, 'unreadable_image');
        $types = ['jpg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp'];
        if (!function_exists('imagecreatefromstring')) return [$raw, $types[$kind], $kind]; // hébergement sans GD : image gardée telle quelle

        $img = @imagecreatefromstring($raw);
        if (!$img) throw new AppError(415, 'unreadable_image');
        if ($kind === 'jpg' && function_exists('exif_read_data')) {
            $exif = @exif_read_data('data://image/jpeg;base64,' . base64_encode($raw));
            $turn = [3 => 180, 6 => -90, 8 => 90][(int) ($exif['Orientation'] ?? 0)] ?? 0;
            if ($turn && ($rot = imagerotate($img, $turn, 0))) { imagedestroy($img); $img = $rot; }
        }
        $w = imagesx($img);
        $h = imagesy($img);
        $scale = min(1.0, self::MAX_SIDE / max($w, $h));
        if ($scale < 1.0) {
            $nw = max(1, (int) round($w * $scale));
            $nh = max(1, (int) round($h * $scale));
            $dst = imagecreatetruecolor($nw, $nh);
            imagefill($dst, 0, 0, (int) imagecolorallocate($dst, 255, 255, 255));
            imagecopyresampled($dst, $img, 0, 0, 0, 0, $nw, $nh, $w, $h);
            imagedestroy($img);
            $img = $dst;
        } elseif (!imageistruecolor($img)) {
            imagepalettetotruecolor($img);
        }
        ob_start();
        $webp = function_exists('imagewebp');
        $ok = $webp ? @imagewebp($img, null, 80) : @imagejpeg($img, null, 82);
        $out = (string) ob_get_clean();
        imagedestroy($img);
        if (!$ok || $out === '') throw new AppError(415, 'unreadable_image');
        return $webp ? [$out, 'image/webp', 'webp'] : [$out, 'image/jpeg', 'jpg'];
    }

    /**
     * Demande à Gemini un titre + une description à partir des photos. Volontairement strict :
     * le modèle ne doit jamais inventer une marque, un état ou un prix qu'il ne voit pas.
     * @param list<array<string,mixed>> $images
     * @return array{title:string, description:string}
     */
    private static function suggest(string $apiKey, array $images): array
    {
        $prompt = "Tu regardes une ou plusieurs photos d'un article mis en vente sur une marketplace de seconde main au Cameroun. Rédige en français :\n"
            . "- \"title\" : un titre court et honnête (max 100 caractères), basé UNIQUEMENT sur ce qui est visible.\n"
            . "- \"description\" : 2 à 4 phrases décrivant l'article (type d'objet, couleur, matière apparente, état visuel général). "
            . "N'invente jamais une marque, un modèle, un prix ou un état que tu ne peux pas vérifier sur l'image ; si tu n'es pas sûr d'un détail, ne le mentionne pas. "
            . "Ne mentionne jamais le prix.\nRéponds uniquement avec un objet JSON {\"title\": \"...\", \"description\": \"...\"}, sans texte autour.";
        $payload = ['contents' => [['parts' => array_merge([['text' => $prompt]], $images)]],
                    'generationConfig' => ['responseMimeType' => 'application/json', 'maxOutputTokens' => 400]];
        $base = 'https://generativelanguage.googleapis.com/v1beta/';
        $model = App::$settings->str('gemini.model');
        $call = fn (string $m) => Http::json('POST', $base . 'models/' . rawurlencode($m) . ':generateContent', ['x-goog-api-key' => $apiKey], $payload, 30);
        $res = $call($model);
        if ($res['status'] === 404) {
            // Le modèle réglé n'existe plus chez Google : on prend le premier modèle « flash » disponible et on le retient.
            $list = Http::json('GET', $base . 'models?pageSize=200', ['x-goog-api-key' => $apiKey], null, 20);
            foreach ($list['json']['models'] ?? [] as $m) {
                $name = substr((string) ($m['name'] ?? ''), 7);
                if (str_contains($name, 'flash') && !preg_match('/tts|image|audio|live|embedding/', $name)
                    && in_array('generateContent', $m['supportedGenerationMethods'] ?? [], true)) {
                    $res = $call($name);
                    if ($res['status'] === 200) { App::$settings->set('gemini.model', $name); break; }
                }
            }
        }
        if ($res['status'] !== 200) throw new \RuntimeException("gemini HTTP {$res['status']} " . Util::clip((string) json_encode($res['json']['error']['message'] ?? ''), 200));
        $text = $res['json']['candidates'][0]['content']['parts'][0]['text'] ?? null;
        $j = is_string($text) ? json_decode($text, true) : null;
        if (!is_array($j) || !is_string($j['title'] ?? null) || !is_string($j['description'] ?? null)) throw new \RuntimeException('gemini : réponse inattendue');
        return ['title' => Util::clip($j['title'], 120), 'description' => Util::clip($j['description'], 4000)];
    }
}
