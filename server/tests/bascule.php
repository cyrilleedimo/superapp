<?php
// Test de la bascule fichier → MySQL et de la reprise des anciens comptes.
// Prérequis : MySQL local, base vide ovia_t, utilisateur ovia / pw-test-1.
declare(strict_types=1);
$root = dirname(__DIR__); $priv = "$root/public/_ovia"; $port = 8000 + random_int(100, 900); $base = "http://127.0.0.1:$port/api";
@unlink("$priv/config.php"); exec('rm -rf ' . escapeshellarg("$priv/data")); mkdir("$priv/data", 0700, true);
// Ancien compte (hachage argon2id au format de l'ancien serveur Node).
$legacyHash = password_hash('ancien-mot-de-passe', PASSWORD_ARGON2ID, ['memory_cost' => 19456, 'time_cost' => 2, 'threads' => 1]);
file_put_contents("$priv/data/comptes-importes.json", json_encode(['users' => [[
    'id' => 'b9a1cc66-141f-4983-a668-592bcda4721c', 'phone' => '+237699000111', 'email' => null, 'display_name' => 'Ancien Admin',
    'password_hash' => $legacyHash, 'status' => 'active', 'role' => 'admin', 'created_at' => '2026-11-09T04:01:42.500Z'],
    // Compte préparé avec un mot de passe provisoire et un e-mail déjà connu.
    ['id' => 'c0a1cc66-141f-4983-a668-592bcda4721d', 'phone' => '+237699000222', 'email' => 'Prepare@Example.com', 'email_verified' => true,
     'display_name' => 'Compte Préparé', 'temp_password' => '000', 'role' => 'admin']],
    'settings' => ['payments.provider' => 'notchpay', 'notchpay.public_key' => 'pk_test.exemple', 'fees.buyer_bps' => 500, 'inconnu' => 'x']]));
$proc = proc_open(['php', '-S', "127.0.0.1:$port", '-t', "$root/public", "$root/tests/router.php"], [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes, null, ['OVIA_NO_DEMO' => '1'] + getenv());
register_shutdown_function(fn () => proc_terminate($proc)); usleep(600000);
$fail = 0;
function call(string $m, string $path, mixed $body = null, ?string $token = null): array {
    global $base; $ch = curl_init($base . $path); $h = ['Content-Type: application/json']; if ($token) $h[] = "Authorization: Bearer $token";
    curl_setopt_array($ch, [CURLOPT_CUSTOMREQUEST => $m, CURLOPT_RETURNTRANSFER => true, CURLOPT_HTTPHEADER => $h]);
    if ($body !== null) curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
    $out = curl_exec($ch); return [curl_getinfo($ch, CURLINFO_RESPONSE_CODE), json_decode((string) $out, true)];
}
function ok(string $l, bool $c, mixed $x = null): void { global $fail; echo ($c ? 'ok    ' : 'ÉCHEC ') . $l . ($c ? '' : ' ' . json_encode($x)) . "\n"; if (!$c) $fail++; }

[$st] = call('GET', '/health'); ok('démarrage en mode fichier', $st === 200);
ok('fichier des anciens comptes supprimé après reprise', !is_file("$priv/data/comptes-importes.json"));
[$st, $t] = call('POST', '/auth/login', ['identifier' => '+237699000111', 'password' => 'ancien-mot-de-passe']); ok('ancien compte : connexion avec son ancien mot de passe', $st === 200, [$st, $t]);
[$st, $me] = call('GET', '/me', null, $t['accessToken']); ok('ancien compte : admin conservé, e-mail à ajouter', $me['role'] === 'admin' && $me['needsEmail'] === true && $me['id'] === 'b9a1cc66-141f-4983-a668-592bcda4721c', $me);
[$st, $j] = call('POST', '/me/email', ['email' => 'admin@example.com'], $t['accessToken']); ok('ajout e-mail', $st === 202, $j);
$cfg = require "$priv/config.php"; $file = "$priv/data/{$cfg['db_file']}"; $pdo = new PDO("sqlite:$file");
$code = $pdo->query("SELECT code FROM mail_outbox ORDER BY id DESC LIMIT 1")->fetchColumn();
[$st, $j] = call('POST', '/me/email/verify', ['code' => $code], $t['accessToken']); ok('e-mail vérifié', $j['email'] === 'admin@example.com' && $j['needsEmail'] === false, $j);
[$st, $l] = call('POST', '/listings', ['title' => 'Vélo avant bascule', 'category' => 'sports', 'condition' => 'good', 'priceXaf' => 30000, 'city' => 'Douala'], $t['accessToken']); ok('annonce en mode fichier', $st === 201);
[$st, $s] = call('GET', '/admin/system', null, $t['accessToken']); ok('stockage = fichier, paiement repris des réglages importés', $s['storage'] === 'file' && $s['paymentsReady'] === true, $s);
unset($pdo);
// --- mot de passe provisoire : il ne donne accès à rien tant que le vrai n'est pas choisi
[$st, $j] = call('POST', '/auth/login', ['identifier' => '+237699000222', 'password' => '000']); ok('provisoire : pas de session, changement exigé', $st === 409 && $j['error'] === 'password_change_required' && empty($j['accessToken']), [$st, $j]);
[$st, $j] = call('POST', '/auth/login', ['identifier' => '+237699000222', 'password' => '000', 'newPassword' => 'court']); ok('provisoire : nouveau mot de passe trop court refusé', $st === 400 && $j['error'] === 'weak_password', [$st, $j]);
[$st, $j] = call('POST', '/auth/login', ['identifier' => '+237699000222', 'password' => '001', 'newPassword' => 'un-vrai-mot-de-passe']); ok('provisoire : mauvais provisoire refusé', $st === 401, [$st, $j]);
[$st, $p] = call('POST', '/auth/login', ['identifier' => '+237699000222', 'password' => '000', 'newPassword' => 'un-vrai-mot-de-passe']); ok('provisoire : remplacé, session ouverte', $st === 200 && !empty($p['accessToken']), [$st, $p]);
[$st, $me2] = call('GET', '/me', null, $p['accessToken']); ok('compte préparé : admin, e-mail déjà en place', $me2['role'] === 'admin' && $me2['email'] === 'prepare@example.com' && $me2['needsEmail'] === false, $me2);
[$st, $j] = call('POST', '/auth/login', ['identifier' => '+237699000222', 'password' => '000']); ok('provisoire : ne fonctionne plus ensuite', $st === 401, [$st, $j]);
[$st, $j] = call('POST', '/auth/login', ['identifier' => 'prepare@example.com', 'password' => 'un-vrai-mot-de-passe']); ok('connexion normale avec le nouveau mot de passe', $st === 200, [$st, $j]);

// --- la base MySQL contient déjà les tables d'un autre site, dont certaines portent les mêmes noms que les nôtres
$other = new PDO('mysql:host=127.0.0.1;dbname=ovia_t;charset=utf8mb4', 'ovia', 'pw-test-1', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
foreach ($other->query('SHOW TABLES')->fetchAll(PDO::FETCH_COLUMN) as $old) $other->exec("DROP TABLE `$old`");
$other->exec("CREATE TABLE users (id INT PRIMARY KEY, login VARCHAR(40))"); $other->exec("INSERT INTO users VALUES (1,'autre-site'),(2,'encore')");
$other->exec("CREATE TABLE orders (id INT PRIMARY KEY, total INT)"); $other->exec("INSERT INTO orders VALUES (7, 1500)");
$other->exec("CREATE TABLE settings (cle VARCHAR(40) PRIMARY KEY, valeur TEXT)"); $other->exec("INSERT INTO settings VALUES ('theme','rouge')");
$other->exec("CREATE TABLE fah_membres (id INT PRIMARY KEY, nom VARCHAR(40))"); $other->exec("INSERT INTO fah_membres VALUES (1,'A'),(2,'B'),(3,'C')");
$other->exec("CREATE TABLE zz_users (id INT PRIMARY KEY)");
$before = fn () => [$other->query('SELECT group_concat(login ORDER BY id) FROM users')->fetchColumn(), $other->query('SELECT total FROM orders')->fetchColumn(),
                    $other->query('SELECT valeur FROM settings')->fetchColumn(), $other->query('SELECT count(*) FROM fah_membres')->fetchColumn()];
$snap = $before();
[$st, $j] = call('POST', '/admin/database', ['host' => '127.0.0.1', 'name' => 'ovia_t', 'user' => 'ovia', 'pass' => 'pw-test-1', 'prefix' => 'zz_'], $t['accessToken']); ok('préfixe déjà pris par une autre table : refusé, rien ne change', $st === 409 && $j['error'] === 'prefix_taken', [$st, $j]);
[$st, $j] = call('POST', '/admin/database', ['host' => '127.0.0.1', 'name' => 'ovia_t', 'user' => 'ovia', 'pass' => 'pw-test-1', 'prefix' => 'Mauvais-Préfixe'], $t['accessToken']); ok('préfixe invalide refusé', $st === 400, [$st, $j]);
[$st, $s] = call('GET', '/admin/system', null, $t['accessToken']); ok('toujours en mode fichier après les refus', $s['storage'] === 'file', $s);
ok('aucune table Ovia créée après les refus', !in_array('zz_listings', $other->query('SHOW TABLES')->fetchAll(PDO::FETCH_COLUMN), true));
// --- bascule
[$st, $j] = call('POST', '/admin/database', ['host' => '127.0.0.1', 'name' => 'ovia_t', 'user' => 'ovia', 'pass' => 'mauvais'], $t['accessToken']); ok('mauvais accès MySQL refusé, rien ne change', $st === 400 && $j['error'] === 'database_unreachable', [$st, $j]);
[$st, $j] = call('POST', '/admin/database', ['host' => '127.0.0.1', 'name' => 'ovia_t', 'user' => 'ovia', 'pass' => 'pw-test-1'], $t['accessToken']); ok('accès MySQL enregistrés', $st === 200, [$st, $j]);
[$st, $s] = call('GET', '/admin/system', null, $t['accessToken']); ok('stockage = MySQL (même session toujours valide)', $st === 200 && $s['storage'] === 'mysql', [$st, $s]);
ok('fichier supprimé après la bascule', !is_file($file) && !is_file("$file-wal"));
[$st, $j] = call('GET', '/listings'); ok('annonce retrouvée dans MySQL', count($j['items']) === 1 && $j['items'][0]['title'] === 'Vélo avant bascule', $j);
[$st, $j] = call('POST', '/auth/login', ['identifier' => 'admin@example.com', 'password' => 'ancien-mot-de-passe']); ok('connexion par e-mail après bascule', $st === 200, [$st, $j]);
$tables = $other->query('SHOW TABLES')->fetchAll(PDO::FETCH_COLUMN);
ok('tables Ovia créées avec le préfixe ovia_', in_array('ovia_users', $tables, true) && in_array('ovia_orders', $tables, true) && in_array('ovia_schema_migrations', $tables, true), $tables);
ok('tables de l\'autre site intactes (mêmes lignes qu\'avant)', $before() === $snap, [$snap, $before()]);
ok('comptes Ovia dans ovia_users, pas dans users', (int) $other->query('SELECT count(*) FROM ovia_users')->fetchColumn() === 2 && (int) $other->query('SELECT count(*) FROM users')->fetchColumn() === 2);
[$st, $l2] = call('POST', '/listings', ['title' => 'Après bascule', 'category' => 'other', 'condition' => 'new', 'priceXaf' => 100, 'city' => 'Douala'], $j['accessToken']); ok('écriture dans MySQL', $st === 201);
echo $fail ? "\n$fail échec(s)\n" : "\nBascule : tout est bon\n"; exit($fail ? 1 : 0);
