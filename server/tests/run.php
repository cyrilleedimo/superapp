<?php
// Tests de bout en bout de l'API : php tests/run.php  (lance son propre serveur local, données jetables).
declare(strict_types=1);
$root = dirname(__DIR__);
$priv = "$root/public/_ovia";
$port = 8000 + random_int(100, 900);
$base = "http://127.0.0.1:$port/api";
$keep = getenv('KEEP_CONFIG');
foreach (["$priv/config.php"] as $f) if (is_file($f) && !$keep) unlink($f);
exec('rm -rf ' . escapeshellarg("$priv/data"));
if ($argv[1] ?? '' === 'with-import') {}
// Les annonces d'exemple ne s'installent pas toutes seules pendant les tests (elles ont leur propre test plus bas).
$proc = proc_open(['php', '-S', "127.0.0.1:$port", '-t', "$root/public", "$root/tests/router.php"], [1 => ['file', '/tmp/ovia-test-server.log', 'w'], 2 => ['file', '/tmp/ovia-test-server.log', 'a']], $pipes, null, ['OVIA_NO_DEMO' => '1'] + getenv());
register_shutdown_function(function () use ($proc) { proc_terminate($proc); });
usleep(600000);

$pass = 0; $fail = 0;
function call(string $m, string $path, mixed $body = null, ?string $token = null, array $headers = [], bool $raw = false): array {
    global $base;
    $ch = curl_init($base . $path);
    $h = $headers;
    if ($token) $h[] = "Authorization: Bearer $token";
    if ($body !== null && !$raw) { $h[] = 'Content-Type: application/json'; $body = json_encode($body); }
    curl_setopt_array($ch, [CURLOPT_CUSTOMREQUEST => $m, CURLOPT_RETURNTRANSFER => true, CURLOPT_HTTPHEADER => $h, CURLOPT_TIMEOUT => 30]);
    if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
    $out = curl_exec($ch);
    $st = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    return [$st, json_decode((string) $out, true) ?? $out];
}
function ok(string $label, bool $cond, mixed $ctx = null): void {
    global $pass, $fail;
    if ($cond) { $pass++; return; }
    $fail++;
    echo "ÉCHEC : $label " . ($ctx !== null ? json_encode($ctx, JSON_UNESCAPED_UNICODE) : '') . "\n";
}
function db(): PDO {
    global $priv;
    $cfg = require "$priv/config.php";
    if (!empty($cfg['mysql'])) { $m = $cfg['mysql']; return new PDO("mysql:host={$m['host']};port={$m['port']};dbname={$m['name']};charset=utf8mb4", $m['user'], $m['pass']); }
    return new PDO("sqlite:$priv/data/{$cfg['db_file']}");
}
function lastCode(string $email): ?string {
    $st = db()->prepare('SELECT code FROM mail_outbox WHERE to_email=? AND code IS NOT NULL ORDER BY id DESC LIMIT 1');
    $st->execute([$email]);
    $c = $st->fetchColumn();
    return $c === false ? null : (string) $c;
}
function signup(string $name, string $email, ?string $phone = null): array {
    [$st, $j] = call('POST', '/auth/register', ['displayName' => $name, 'email' => $email, 'password' => 'motdepasse-123'] + ($phone ? ['phone' => $phone] : []));
    ok("inscription $email", $st === 201, [$st, $j]);
    [$st, $j] = call('POST', '/auth/verify-email', ['email' => $email, 'code' => lastCode(strtolower($email)), 'verifyToken' => $j['verifyToken']]);
    ok("vérification $email", $st === 200 && isset($j['accessToken']), [$st, $j]);
    return $j;
}
$idem = fn () => ['Idempotency-Key: ' . bin2hex(random_bytes(12))];

// ---------------------------------------------------------------- Santé + protection
[$st, $j] = call('GET', '/health'); ok('health', $st === 200 && $j['ok'] === true, [$st, $j]);
$st = (int) explode(' ', get_headers("http://127.0.0.1:$port/_ovia/config.php")[0])[1]; ok('dossier privé inaccessible', $st === 403, $st);
[$st] = call('GET', '/me'); ok('me sans jeton = 401', $st === 401);
[$st, $j] = call('GET', '/listings'); ok('annonces visibles sans compte', $st === 200 && $j['items'] === [], [$st, $j]);
[$st, $j] = call('GET', '/payments/options'); ok('options paiement publiques', $st === 200 && $j['cash'] === true && $j['online'] === false, $j);

// active le faux prestataire de paiement pour les tests
$cfg = require "$priv/config.php"; $cfg['allow_sandbox'] = true;
file_put_contents("$priv/config.php", "<?php\nreturn " . var_export($cfg, true) . ";\n");
if (function_exists('opcache_reset')) opcache_reset();

// ---------------------------------------------------------------- Comptes
[$st, $j] = call('POST', '/auth/register', ['displayName' => 'A', 'email' => 'pasunemail', 'password' => 'x']); ok('inscription invalide = 400', $st === 400, [$st, $j]);
[$st, $j] = call('POST', '/auth/register', ['displayName' => 'Paul', 'email' => 'paul@example.com', 'password' => 'court']); ok('mot de passe faible', $st === 400 && $j['error'] === 'weak_password', $j);
$admin = signup('Paul Admin', 'Paul@Example.com'); // casse ignorée
$adminTok = $admin['accessToken'];
[$st, $me] = call('GET', '/me', null, $adminTok); ok('premier compte = admin', $me['role'] === 'admin' && $me['email'] === 'paul@example.com' && $me['needsEmail'] === false, $me);
// le jeton d'accès porte le rôle au moment de l'émission : on se reconnecte
[$st, $j] = call('POST', '/auth/login', ['identifier' => 'paul@example.com', 'password' => 'motdepasse-123']); ok('connexion e-mail', $st === 200, [$st, $j]); $adminTok = $j['accessToken'];
[$st, $j] = call('POST', '/auth/register', ['displayName' => 'Paul 2', 'email' => 'paul@example.com', 'password' => 'motdepasse-123']); ok('doublon = 409', $st === 409 && $j['error'] === 'account_exists', $j);
$seller = signup('Awa Vendeuse', 'awa@example.com', '+237670000001'); $sellerTok = $seller['accessToken'];
$buyer = signup('Ben Acheteur', 'ben@example.com', '+237670000002'); $buyerTok = $buyer['accessToken'];
[$st, $j] = call('POST', '/auth/login', ['identifier' => '+237 670 00 00 02', 'password' => 'motdepasse-123']); ok('connexion par téléphone', $st === 200, [$st, $j]);
[$st, $j] = call('POST', '/auth/login', ['identifier' => 'ben@example.com', 'password' => 'mauvais']); ok('mauvais mot de passe = 401', $st === 401 && $j['error'] === 'invalid_credentials', $j);
// inscription non terminée : un tiers ne peut ni la détourner ni utiliser le code
[$st, $reg] = call('POST', '/auth/register', ['displayName' => 'Cléo', 'email' => 'cleo@example.com', 'password' => 'motdepasse-123']);
$victimCode = lastCode('cleo@example.com');
[$st, $j] = call('POST', '/auth/register', ['displayName' => 'Pirate', 'email' => 'cleo@example.com', 'password' => 'mot-du-pirate-1']); ok('ré-inscription immédiate par un tiers bloquée', $st === 429, [$st, $j]);
[$st, $j] = call('POST', '/auth/verify-email', ['email' => 'cleo@example.com', 'code' => $victimCode, 'verifyToken' => 'jeton-invente-par-un-tiers']); ok('code inutilisable sans le jeton de l\'appareil', $st === 401, [$st, $j]);
[$st, $j] = call('POST', '/auth/verify-email', ['email' => 'cleo@example.com', 'code' => '000000', 'verifyToken' => $reg['verifyToken']]); ok('mauvais code = 401', $st === 401, [$st, $j]);
// connexion avant vérification → 403 + nouveau code lié à cet appareil
db()->exec("UPDATE otp_codes SET created_at='2020-01-01 00:00:00'");
[$st, $j] = call('POST', '/auth/login', ['identifier' => 'cleo@example.com', 'password' => 'motdepasse-123']); ok('non vérifié = 403 avec jeton', $st === 403 && $j['error'] === 'email_not_verified' && isset($j['verifyToken']), [$st, $j]);
[$st, $x] = call('POST', '/auth/verify-email', ['email' => 'cleo@example.com', 'code' => $victimCode, 'verifyToken' => $reg['verifyToken']]); ok('ancien code remplacé', $st === 401, [$st, $x]);
[$st, $j] = call('POST', '/auth/verify-email', ['email' => 'cleo@example.com', 'code' => lastCode('cleo@example.com'), 'verifyToken' => $j['verifyToken']]); ok('bon code + bon jeton', $st === 200, [$st, $j]); $cleoTok = $j['accessToken'];
[$st, $c] = call('GET', '/me', null, $cleoTok); ok('2e compte = simple utilisateur', $c['role'] === 'user', $c); $cleoId = $c['id'];
// rotation des jetons + détection de réutilisation
[$st, $r1] = call('POST', '/auth/refresh', ['refreshToken' => $buyer['refreshToken']]); ok('refresh', $st === 200, [$st, $r1]);
[$st, $j] = call('POST', '/auth/refresh', ['refreshToken' => $buyer['refreshToken']]); ok('réutilisation détectée', $st === 401 && $j['error'] === 'refresh_reuse_detected', $j);
[$st, $j] = call('POST', '/auth/refresh', ['refreshToken' => $r1['refreshToken']]); ok('famille révoquée', $st === 401, [$st, $j]);
[$st, $j] = call('POST', '/auth/login', ['identifier' => 'ben@example.com', 'password' => 'motdepasse-123']); $buyerTok = $j['accessToken'];
// mot de passe oublié
[$st, $j] = call('POST', '/auth/forgot-password', ['email' => 'inconnu@example.com']); ok('oubli : même réponse si inconnu', $st === 202, [$st, $j]);
[$st, $j] = call('POST', '/auth/forgot-password', ['email' => 'cleo@example.com']); ok('oubli', $st === 202);
[$st, $j] = call('POST', '/auth/reset-password', ['email' => 'cleo@example.com', 'code' => lastCode('cleo@example.com'), 'password' => 'nouveau-secret-9']); ok('réinitialisation', $st === 200 && isset($j['accessToken']), [$st, $j]);
[$st, $j] = call('POST', '/auth/login', ['identifier' => 'cleo@example.com', 'password' => 'motdepasse-123']); ok('ancien mot de passe refusé', $st === 401);
[$st, $j] = call('POST', '/auth/login', ['identifier' => 'cleo@example.com', 'password' => 'nouveau-secret-9']); ok('nouveau mot de passe accepté', $st === 200); $cleoTok = $j['accessToken'];
[$st, $j] = call('GET', '/admin/metrics', null, $buyerTok); ok('admin interdit aux autres', $st === 403);
[$st, $j] = call('GET', '/me', null, 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.'); ok('jeton alg none refusé', $st === 401);

// ---------------------------------------------------------------- Réglages admin
[$st, $j] = call('PATCH', '/admin/settings', ['notchpay.public_key' => 'sk_test.abc'], $adminTok); ok('clé secrète refusée à la place de la publique', $st === 400 && $j['error'] === 'wrong_key_type', $j);
[$st, $j] = call('PATCH', '/admin/settings', ['payments.provider' => 'sandbox', 'rides.base_xaf' => 500, 'rides.per_km_xaf' => 200, 'gemini.api_key' => 'cle-secrete-123'], $adminTok); ok('réglages', $st === 200, [$st, $j]);
[$st, $j] = call('GET', '/admin/settings', null, $adminTok); ok('secret masqué', $j['settings']['gemini.api_key']['isSet'] === true && !isset($j['settings']['gemini.api_key']['value']) && $j['settings']['fees.buyer_bps']['value'] === 500, $j['settings']['gemini.api_key'] ?? null);
$stored = db()->query("SELECT v FROM settings WHERE k='gemini.api_key'")->fetchColumn(); ok('secret chiffré en base', !str_contains((string) $stored, 'cle-secrete'), $stored);
[$st, $j] = call('GET', '/admin/system', null, $adminTok); ok('système', $st === 200 && $j['paymentsReady'] === true, $j);
[$st, $j] = call('GET', '/admin/users?q=awa', null, $adminTok); ok('recherche utilisateurs', count($j['items']) === 1, $j);

// ---------------------------------------------------------------- Annonces + photo
$im = imagecreatetruecolor(2400, 1200); imagefill($im, 0, 0, imagecolorallocate($im, 40, 60, 240)); ob_start(); imagepng($im); $png = ob_get_clean();
[$st, $media] = call('POST', '/media', $png, $sellerTok, ['Content-Type: image/png'], true); ok('envoi photo', $st === 201 && str_starts_with($media['url'] ?? '', '/media/'), [$st, $media]);
[$st, $j] = call('POST', '/media', '<?php echo 1;', $sellerTok, ['Content-Type: image/png'], true); ok('faux fichier refusé', $st === 415, [$st, $j]);
[$st, $img] = call('GET', $media['url']); ok('photo servie', $st === 200 && is_string($img) && strlen($img) > 20);
[$st, $l] = call('POST', '/listings', ['title' => 'Téléphone Élégant', 'description' => 'Très bon état, écran neuf', 'category' => 'electronics', 'condition' => 'very_good', 'priceXaf' => 10000, 'city' => 'Douala', 'photos' => [$media['url']]], $sellerTok);
ok('annonce créée', $st === 201 && $l['condition'] === 'very_good' && $l['photos'] === [$media['url']], [$st, $l]);
[$st, $l2] = call('POST', '/listings', ['title' => 'Robe wax', 'category' => 'women', 'condition' => 'good', 'priceXaf' => 5000, 'city' => 'Yaoundé'], $sellerTok); ok('annonce 2', $st === 201, $l2);
[$st, $j] = call('POST', '/listings', ['title' => 'x', 'category' => 'women', 'condition' => 'good', 'priceXaf' => -1, 'city' => 'Y'], $sellerTok); ok('annonce invalide', $st === 400);
[$st, $j] = call('GET', '/listings?q=' . urlencode('telephone ELEGANT')); ok('recherche sans accents', count($j['items']) === 1, $j);
[$st, $j] = call('GET', '/listings?city=yaounde'); ok('filtre ville sans accent', count($j['items']) === 1 && $j['items'][0]['title'] === 'Robe wax', $j);
[$st, $j] = call('GET', '/listings?limit=1'); ok('pagination page 1', count($j['items']) === 1 && $j['nextCursor'] !== null, $j);
[$st, $j2] = call('GET', '/listings?limit=1&cursor=' . $j['nextCursor']); ok('pagination page 2', count($j2['items']) === 1 && $j2['items'][0]['id'] !== $j['items'][0]['id'] && $j2['nextCursor'] === null, $j2);
[$st, $j] = call('GET', "/listings/{$l['id']}"); ok('détail public + vendeur', $j['seller']['displayName'] === 'Awa Vendeuse', $j);
[$st, $j] = call('PATCH', "/listings/{$l['id']}", ['priceXaf' => 12000], $buyerTok); ok('modif par un autre = 403', $st === 403);
[$st, $j] = call('PATCH', "/listings/{$l['id']}", ['priceXaf' => 12000], $sellerTok); ok('modif prix', $j['priceXaf'] === 12000, $j);

// ---------------------------------------------------------------- Messagerie + offre
[$st, $conv] = call('POST', '/conversations', ['listingId' => $l['id']], $buyerTok); ok('conversation', $st === 201, $conv);
[$st, $j] = call('POST', '/conversations', ['listingId' => $l['id']], $sellerTok); ok('pas de conversation avec soi-même', $st === 403);
[$st, $j] = call('POST', "/conversations/{$conv['id']}/messages", ['body' => 'Bonjour, toujours dispo ?'], $buyerTok); ok('message envoyé', $st === 201, $j);
$sealed = db()->query('SELECT body FROM messages ORDER BY id DESC LIMIT 1')->fetchColumn(); ok('message chiffré en base', !str_contains((string) $sealed, 'Bonjour'), $sealed);
[$st, $j] = call('GET', '/me/badges', null, $sellerTok); ok('pastilles vendeur', $j['messages'] === 1 && $j['notifications'] >= 1, $j);
[$st, $j] = call('GET', '/conversations', null, $sellerTok); ok('liste côté vendeur', $j['items'][0]['unread'] === 1 && $j['items'][0]['lastMessage'] === 'Bonjour, toujours dispo ?' && $j['items'][0]['otherName'] === 'Ben Acheteur', $j);
[$st, $j] = call('GET', "/conversations/{$conv['id']}/messages", null, $sellerTok); ok('lecture messages', count($j['items']) === 1 && $j['items'][0]['senderName'] === 'Ben Acheteur', $j);
[$st, $j] = call('GET', '/me/badges', null, $sellerTok); ok('lu → pastille à 0', $j['messages'] === 0, $j);
[$st, $j] = call('GET', "/conversations/{$conv['id']}/messages", null, $cleoTok); ok('étranger = 404', $st === 404);
[$st, $offer] = call('POST', "/conversations/{$conv['id']}/offers", ['amountXaf' => 9000], $buyerTok); ok('offre', $st === 201, $offer);
[$st, $j] = call('POST', "/offers/{$offer['id']}/decision", ['accept' => true], $sellerTok); ok('offre acceptée', $j['status'] === 'accepted', $j);
// discussion privée + groupe
[$st, $j] = call('GET', '/users/search?q=' . urlencode('cléo'), null, $buyerTok); ok('recherche personne (accents)', count($j['items']) === 1 && $j['items'][0]['id'] === $cleoId, $j);
[$st, $d1] = call('POST', '/conversations/direct', ['userId' => $cleoId], $buyerTok); [$st, $d2] = call('POST', '/conversations/direct', ['userId' => $buyer ? json_decode(base64_decode(explode('.', $buyerTok)[1]), true)['sub'] : ''], $cleoTok);
ok('discussion privée unique', $d1['id'] === $d2['id'], [$d1, $d2]);
$sellerId = json_decode(base64_decode(explode('.', $sellerTok)[1]), true)['sub'];
[$st, $g] = call('POST', '/groups', ['title' => 'Équipe Douala', 'memberIds' => [$cleoId, $sellerId]], $buyerTok); ok('groupe créé', $st === 201, $g);
[$st, $j] = call('POST', "/conversations/{$g['id']}/messages", ['body' => 'Bienvenue à tous'], $cleoTok); ok('message de groupe', $st === 201);
[$st, $j] = call('GET', "/conversations/{$g['id']}", null, $sellerTok); ok('détail groupe', $j['kind'] === 'group' && count($j['members']) === 3 && $j['title'] === 'Équipe Douala', $j);
[$st, $j] = call('POST', "/groups/{$g['id']}/members", ['userId' => $cleoId], $cleoTok); ok('seul le responsable ajoute', $st === 403);
[$st, $j] = call('POST', "/groups/{$g['id']}/leave", null, $buyerTok); ok('quitter le groupe', $st === 204, [$st, $j]);
[$st, $j] = call('GET', "/conversations/{$g['id']}", null, $cleoTok); ok('nouveau responsable désigné', count(array_filter($j['members'], fn ($m) => $m['role'] === 'admin')) === 1, $j);

// ---------------------------------------------------------------- Commande en ligne (séquestre)
$k = $idem();
[$st, $o] = call('POST', '/orders', ['listingId' => $l['id'], 'offerId' => $offer['id']], $buyerTok, $k); ok('commande au prix négocié', $st === 201 && $o['itemPriceXaf'] === 9000 && $o['buyerFeeXaf'] === 450 && $o['totalXaf'] === 9450, [$st, $o]);
[$st, $o2] = call('POST', '/orders', ['listingId' => $l['id'], 'offerId' => $offer['id']], $buyerTok, $k); ok('idempotence', $o2['id'] === $o['id'], $o2);
[$st, $j] = call('POST', '/orders', ['listingId' => $l['id']], $cleoTok, $idem()); ok('double vente impossible', $st === 409 && $j['error'] === 'listing_unavailable', $j);
[$st, $j] = call('GET', '/listings'); ok('article réservé retiré du fil', count($j['items']) === 1, $j);
[$st, $pay] = call('POST', "/orders/{$o['id']}/pay", null, $buyerTok); ok('paiement ouvert', $st === 200 && str_starts_with($pay['checkoutUrl'], 'https://'), [$st, $pay]);
[$st, $j] = call('POST', "/payments/{$pay['reference']}/refresh", null, $buyerTok); ok('paiement en attente', $j['status'] === 'pending', $j);
// le prestataire confirme (simulation) puis webhook signé
$sbxFile = "$priv/data/sandbox-payments.json"; $sbx = json_decode(file_get_contents($sbxFile), true); $pref = array_key_first($sbx); $sbx[$pref]['status'] = 'succeeded'; file_put_contents($sbxFile, json_encode($sbx));
$hook = json_encode(['event' => 'payment.complete', 'data' => ['reference' => $pref]]);
[$st, $j] = call('POST', '/webhooks/payments', $hook, null, ['Content-Type: application/json', 'X-Sandbox-Signature: mauvaise'], true); ok('webhook mal signé = 401', $st === 401);
$sig = hash_hmac('sha256', $hook, (require "$priv/config.php")['data_key']);
[$st, $j] = call('POST', '/webhooks/payments', $hook, null, ['Content-Type: application/json', "X-Sandbox-Signature: $sig"], true); ok('webhook → payé', $st === 200 && $j['outcome'] === 'succeeded', [$st, $j]);
[$st, $j] = call('POST', '/webhooks/payments', $hook, null, ['Content-Type: application/json', "X-Sandbox-Signature: $sig"], true); ok('webhook rejoué ignoré', $j['outcome'] === 'duplicate', $j);
[$st, $j] = call('GET', "/orders/{$o['id']}", null, $sellerTok); ok('commande payée vue par le vendeur', $j['status'] === 'paid' && $j['otherName'] === 'Ben Acheteur', $j);
[$st, $j] = call('GET', '/me/wallet', null, $sellerTok); ok('porte-monnaie vide tant que non confirmé', $j['availableXaf'] === 0, $j);
[$st, $j] = call('POST', "/orders/{$o['id']}/confirm", null, $sellerTok); ok('le vendeur ne peut pas confirmer', $st === 404);
[$st, $j] = call('POST', "/orders/{$o['id']}/confirm", null, $buyerTok); ok('réception confirmée', $j['status'] === 'completed', $j);
[$st, $j] = call('GET', '/me/wallet', null, $sellerTok); ok('vendeur crédité', $j['availableXaf'] === 9000, $j);
[$st, $j] = call('GET', "/listings/{$l['id']}"); ok('article vendu', $j['status'] === 'sold', $j);
$sum = (int) db()->query('SELECT coalesce(sum(amount_xaf),0) FROM ledger_entries')->fetchColumn(); ok('grand livre équilibré', $sum === 0, $sum);
// retrait : mot de passe exigé
[$st, $j] = call('POST', '/payouts', ['amountXaf' => 9000, 'msisdn' => '+237670000001', 'channel' => 'mtn_momo'], $sellerTok); ok('retrait sans mot de passe refusé', $st === 403 && $j['error'] === 'password_required', $j);
[$st, $j] = call('POST', '/payouts', ['amountXaf' => 99000, 'msisdn' => '+237670000001', 'channel' => 'mtn_momo', 'password' => 'motdepasse-123'], $sellerTok); ok('solde insuffisant', $st === 409, $j);
[$st, $po] = call('POST', '/payouts', ['amountXaf' => 9000, 'msisdn' => '+237670000001', 'channel' => 'mtn_momo', 'password' => 'motdepasse-123'], $sellerTok); ok('retrait demandé', $st === 201, $po);
[$st, $j] = call('POST', "/admin/payouts/{$po['id']}/decision", ['paid' => false], $adminTok); ok('retrait refusé', $j['status'] === 'rejected', $j);
[$st, $j] = call('GET', '/me/wallet', null, $sellerTok); ok('solde restitué', $j['availableXaf'] === 9000, $j);

// ---------------------------------------------------------------- Paiement à la remise + litige
[$st, $o3] = call('POST', '/orders', ['listingId' => $l2['id']], $buyerTok, $idem()); ok('commande 2', $st === 201 && $o3['totalXaf'] === 5250, $o3);
[$st, $j] = call('POST', "/orders/{$o3['id']}/pay-cash", null, $buyerTok); ok('payer à la remise : sans frais', $j['status'] === 'cash_due' && $j['buyerFeeXaf'] === 0 && $j['totalXaf'] === 5000 && $j['paymentMethod'] === 'cash', $j);
[$st, $j] = call('GET', "/orders/{$o3['id']}", null, $buyerTok); ok('numéro du vendeur visible pour la remise', $j['otherPhone'] === '+237670000001', $j);
[$st, $j] = call('POST', "/orders/{$o3['id']}/dispute", ['reason' => 'problème important ici'], $buyerTok); ok('pas de litige sans séquestre', $st === 409);
[$st, $j] = call('POST', "/orders/{$o3['id']}/cancel", null, $sellerTok); ok('annulation par le vendeur', $j['status'] === 'cancelled', $j);
[$st, $j] = call('GET', "/listings/{$l2['id']}"); ok('article de nouveau disponible', $j['status'] === 'active', $j);
[$st, $o4] = call('POST', '/orders', ['listingId' => $l2['id']], $cleoTok, $idem());
[$st, $j] = call('POST', "/orders/{$o4['id']}/pay-cash", null, $cleoTok); [$st, $j] = call('POST', "/orders/{$o4['id']}/confirm", null, $cleoTok); ok('remise confirmée', $j['status'] === 'completed', $j);
[$st, $j] = call('GET', '/me/wallet', null, $sellerTok); ok('remise en main propre : porte-monnaie inchangé', $j['availableXaf'] === 9000, $j);

// ---------------------------------------------------------------- Boutique + litige remboursé
[$st, $store] = call('POST', '/stores', ['kind' => 'shop', 'name' => 'Chez Awa', 'city' => 'Douala', 'deliveryFeeXaf' => 500], $sellerTok); ok('boutique créée', $st === 201 && $store['approved'] === false, $store);
[$st, $j] = call('GET', '/stores?kind=shop'); ok('boutique invisible avant validation', $j['items'] === [], $j);
[$st, $j] = call('POST', "/admin/stores/{$store['id']}/approve", null, $adminTok); ok('boutique validée', $j['approved'] === true, $j);
[$st, $prod] = call('POST', "/stores/{$store['id']}/products", ['name' => 'Savon', 'priceXaf' => 1000, 'stock' => 3], $sellerTok); ok('produit', $st === 201 && $prod['stock'] === 3, $prod);
[$st, $j] = call('POST', "/stores/{$store['id']}/orders", ['items' => [['productId' => $prod['id'], 'qty' => 5]]], $buyerTok, $idem()); ok('rupture de stock', $st === 409 && $j['error'] === 'out_of_stock', $j);
[$st, $so] = call('POST', "/stores/{$store['id']}/orders", ['items' => [['productId' => $prod['id'], 'qty' => 2]]], $buyerTok, $idem()); ok('commande boutique', $st === 201 && $so['itemPriceXaf'] === 2500 && $so['kind'] === 'shop', $so);
[$st, $pay2] = call('POST', "/orders/{$so['id']}/pay-mobile", ['phone' => '+237670000002'], $buyerTok); ok('paiement direct mobile', $st === 200 && $pay2['status'] === 'processing', [$st, $pay2]);
$sbx = json_decode(file_get_contents($sbxFile), true); foreach ($sbx as $kk => $v) if ($v['status'] === 'pending') $sbx[$kk]['status'] = 'succeeded'; file_put_contents($sbxFile, json_encode($sbx));
[$st, $j] = call('POST', "/payments/{$pay2['reference']}/refresh", null, $buyerTok); ok('paiement confirmé par interrogation', $j['status'] === 'succeeded', $j);
[$st, $j] = call('POST', "/orders/{$so['id']}/fulfillment", ['step' => 'preparing'], $sellerTok); ok('préparation', $j['fulfillment'] === 'preparing', $j);
[$st, $j] = call('POST', "/orders/{$so['id']}/fulfillment", ['step' => 'accepted'], $sellerTok); ok('retour en arrière interdit', $st === 409);
[$st, $j] = call('POST', "/orders/{$so['id']}/dispute", ['reason' => 'Colis jamais reçu malgré relances'], $buyerTok); ok('litige', $j['status'] === 'disputed', $j);
[$st, $j] = call('GET', '/admin/disputes', null, $adminTok); ok('litige visible admin', count($j['items']) === 1 && str_contains($j['items'][0]['reason'], 'Colis'), $j);
[$st, $j] = call('POST', "/admin/orders/{$so['id']}/refund", null, $adminTok); ok('remboursement', $j['status'] === 'refunded', $j);
$stock = (int) db()->query("SELECT stock FROM products WHERE id='{$prod['id']}'")->fetchColumn(); ok('stock restitué', $stock === 3, $stock);
$sum = (int) db()->query('SELECT coalesce(sum(amount_xaf),0) FROM ledger_entries')->fetchColumn(); ok('grand livre toujours équilibré', $sum === 0, $sum);

// ---------------------------------------------------------------- Covoiturage
$dep = gmdate('Y-m-d\TH:i:s\Z', time() + 86400);
[$st, $trip] = call('POST', '/trips', ['fromCity' => 'Douala', 'toCity' => 'Yaoundé', 'departAt' => $dep, 'seats' => 3, 'pricePerSeatXaf' => 4000], $sellerTok); ok('trajet publié', $st === 201, $trip);
[$st, $j] = call('GET', '/trips?from=douala&to=yaounde'); ok('recherche trajet sans accents', count($j['items']) === 1 && $j['items'][0]['seatsLeft'] === 3, $j);
[$st, $bo] = call('POST', "/trips/{$trip['id']}/book", ['seats' => 2], $buyerTok, $idem()); ok('réservation 2 places', $st === 201 && $bo['itemPriceXaf'] === 8000, $bo);
[$st, $j] = call('POST', "/trips/{$trip['id']}/book", ['seats' => 2], $cleoTok, $idem()); ok('plus assez de places', $st === 409 && $j['error'] === 'not_enough_seats', $j);
[$st, $j] = call('POST', "/trips/{$trip['id']}/cancel", null, $sellerTok); ok('trajet réservé non annulable', $st === 409);
[$st, $j] = call('POST', "/orders/{$bo['id']}/cancel", null, $buyerTok); [$st, $j] = call('GET', '/trips?from=Douala&to=' . urlencode('Yaoundé')); ok('places rendues', $j['items'][0]['seatsLeft'] === 3, $j);

// ---------------------------------------------------------------- VTC
$pk = ['text' => 'Akwa', 'lat' => 4.05, 'lng' => 9.70]; $dp = ['text' => 'Bonapriso', 'lat' => 4.02, 'lng' => 9.69];
[$st, $j] = call('POST', '/rides/estimate', ['pickup' => $pk, 'dropoff' => $dp]); ok('estimation course', $st === 200 && $j['fareXaf'] > 500, [$st, $j]);
[$st, $j] = call('POST', '/drivers/apply', ['vehicle' => 'Toyota Yaris', 'plate' => 'LT 123 AB'], $sellerTok); ok('candidature chauffeur', $st === 201);
[$st, $j] = call('POST', '/drivers/me/status', ['online' => true, 'lat' => 4.05, 'lng' => 9.70], $sellerTok); ok('non vérifié = 403', $st === 403);
[$st, $j] = call('POST', "/admin/drivers/$sellerId/verify", ['verified' => true], $adminTok); ok('chauffeur vérifié', $j['verified'] === true, $j);
[$st, $j] = call('POST', '/drivers/me/status', ['online' => true, 'lat' => 4.05, 'lng' => 9.70], $sellerTok); ok('en ligne', $j['online'] === true, $j);
[$st, $ride] = call('POST', '/rides', ['pickup' => $pk, 'dropoff' => $dp], $buyerTok); ok('course demandée', $st === 201, $ride);
[$st, $j] = call('POST', '/rides', ['pickup' => $pk, 'dropoff' => $dp], $buyerTok); ok('une seule course active', $st === 409 && $j['error'] === 'ride_already_active', $j);
[$st, $j] = call('GET', '/rides/nearby', null, $sellerTok); ok('course proche visible', count($j['items']) === 1, $j);
[$st, $j] = call('POST', "/rides/{$ride['id']}/accept", null, $sellerTok); ok('course acceptée', $j['status'] === 'accepted', $j);
[$st, $j] = call('GET', '/rides/current', null, $buyerTok); ok('passager voit son chauffeur', $j['ride']['driver']['plate'] === 'LT 123 AB', $j);
foreach (['arrived', 'in_progress', 'completed'] as $s) { [$st, $j] = call('POST', "/rides/{$ride['id']}/status", ['status' => $s], $sellerTok); ok("course $s", $j['status'] === $s, $j); }
[$st, $j] = call('GET', '/travel/flights?from=DLA&to=CDG&departDate=2027-01-01'); ok('voyages : pas de partenaire = 503 honnête', $st === 503 && $j['error'] === 'travel_not_configured', $j);

// ---------------------------------------------------------------- Annonces d'exemple
$im2 = imagecreatetruecolor(900, 600); imagefill($im2, 0, 0, imagecolorallocate($im2, 200, 120, 40)); @mkdir("$priv/demo/img", 0755, true);
$made = []; foreach (json_decode(file_get_contents("$priv/demo/annonces.json"), true) as $it) { $f = "$priv/demo/img/{$it['key']}.img"; if (!is_file($f)) { imagejpeg($im2, $f); $made[] = $f; } }
[$st, $d] = call('POST', '/admin/demo', ['action' => 'install'], $buyerTok); ok('exemples : réservé à l\'admin', $st === 403);
[$st, $d] = call('POST', '/admin/demo', ['action' => 'install'], $adminTok); ok('exemples installés', $st === 200 && $d['active'] === 13 && $d['state'] === 'installed', [$st, $d]);
[$st, $feed] = call('GET', '/listings?limit=50'); $demos = array_values(array_filter($feed['items'], fn ($x) => $x['isDemo']));
ok('exemples visibles, marqués, photo copiée sur le serveur', count($demos) === 13 && str_starts_with($demos[0]['photos'][0], '/media/'), $demos[0] ?? null);
[$st, $j] = call('GET', '/listings?q=pagne'); ok('exemples trouvés par la recherche', count($j['items']) === 1 && $j['items'][0]['isDemo'] === true, $j);
[$st, $j] = call('POST', '/orders', ['listingId' => $demos[0]['id']], $buyerTok, $idem()); ok('exemple non achetable par un utilisateur', $st === 403 && $j['error'] === 'demo_listing', [$st, $j]);
[$st, $j] = call('POST', '/conversations', ['listingId' => $demos[0]['id']], $buyerTok); ok('pas de message sur un exemple', $st === 403 && $j['error'] === 'demo_listing', [$st, $j]);
[$st, $do] = call('POST', '/orders', ['listingId' => $demos[0]['id']], $adminTok, $idem()); ok('l\'admin peut simuler un achat', $st === 201, [$st, $do]);
[$st, $j] = call('POST', "/orders/{$do['id']}/pay-cash", null, $adminTok); [$st, $j] = call('POST', "/orders/{$do['id']}/confirm", null, $adminTok); ok('simulation menée au bout', $j['status'] === 'completed', $j);
[$st, $j] = call('GET', '/users/search?q=Exemples', null, $buyerTok); ok('compte technique des exemples introuvable', $j['items'] === [], $j);
// retrait automatique : seuil atteint → la tâche de fond les retire
[$st, $j] = call('PATCH', '/admin/settings', ['demo.remove_after' => 1], $adminTok);
exec('php ' . escapeshellarg("$priv/cron.php") . ' 2>&1', $cronOut, $cronCode); ok('tâche de fond exécutée', $cronCode === 0, $cronOut);
[$st, $feed] = call('GET', '/listings?limit=50'); ok('exemples retirés automatiquement', count(array_filter($feed['items'], fn ($x) => $x['isDemo'])) === 0, count($feed['items']));
[$st, $s] = call('GET', '/admin/system', null, $adminTok); ok('état : retirés', $s['demo']['state'] === 'removed' && $s['demo']['active'] === 0, $s['demo'] ?? null);
exec('php ' . escapeshellarg("$priv/cron.php")); [$st, $feed] = call('GET', '/listings?limit=50'); ok('ils ne reviennent pas tout seuls', count(array_filter($feed['items'], fn ($x) => $x['isDemo'])) === 0);
[$st, $j] = call('GET', "/orders/{$do['id']}", null, $adminTok); ok('historique de la simulation conservé', $j['status'] === 'completed', $j);
foreach ($made as $f) @unlink($f); if ($made) @rmdir("$priv/demo/img");

// ---------------------------------------------------------------- Divers
[$st, $j] = call('GET', '/notifications', null, $sellerTok); ok('notifications', $st === 200 && $j['unread'] > 3, $j['unread'] ?? null);
[$st, $j] = call('POST', '/notifications/read-all', null, $sellerTok); [$st, $j] = call('GET', '/notifications', null, $sellerTok); ok('tout lu', $j['unread'] === 0);
[$st, $j] = call('POST', '/me/email', ['email' => 'ben2@example.com'], $buyerTok); ok('changement e-mail demandé', $st === 202, [$st, $j]);
[$st, $j] = call('POST', '/me/email/verify', ['code' => lastCode('ben2@example.com')], $buyerTok); ok('e-mail changé', $j['email'] === 'ben2@example.com', $j);
[$st, $j] = call('POST', "/admin/users/$cleoId", ['status' => 'suspended'], $adminTok); [$st, $j] = call('POST', '/auth/login', ['identifier' => 'cleo@example.com', 'password' => 'nouveau-secret-9']); ok('compte suspendu bloqué', $st === 403 && $j['error'] === 'account_suspended', $j);
[$st, $j] = call('GET', '/admin/metrics', null, $adminTok); ok('tableau de bord', $j['totals']['usersTotal'] === 5 && count($j['days']['users']) === 14 && end($j['days']['users'])['count'] === 5, $j['totals'] ?? $j);
[$st, $j] = call('GET', '/admin/mail-log', null, $adminTok); ok('journal e-mails', count($j['items']) > 5, count($j['items'] ?? []));
// verrouillage après 5 échecs
db()->exec('DELETE FROM rate_limits');
for ($i = 0; $i < 5; $i++) call('POST', '/auth/login', ['identifier' => 'awa@example.com', 'password' => 'faux']);
[$st, $j] = call('POST', '/auth/login', ['identifier' => 'awa@example.com', 'password' => 'motdepasse-123']); ok('compte verrouillé après 5 échecs', $st === 423, [$st, $j]);
// limitation de débit sur l'authentification
db()->exec('DELETE FROM rate_limits');
$codes = []; for ($i = 0; $i < 12; $i++) { [$st] = call('POST', '/auth/login', ['identifier' => 'x@example.com', 'password' => 'y']); $codes[] = $st; } ok('limitation de débit (429)', in_array(429, $codes, true), $codes);

echo "\n$pass réussis, $fail échoués\n";
if ($fail) { echo "--- journal serveur ---\n" . substr((string) @file_get_contents('/tmp/ovia-test-server.log'), -1500) . "\n" . substr((string) @file_get_contents("$priv/data/erreurs.log"), -2500); }
exit($fail ? 1 : 0);
