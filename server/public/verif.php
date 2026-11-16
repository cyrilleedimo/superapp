<?php
// Page de contrôle de l'installation Ovia. Ouvre https://TON-SOUS-DOMAINE/verif.php
// Elle n'affiche aucun secret. Tu peux la supprimer une fois que tout est vert.
declare(strict_types=1);
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
$priv = __DIR__ . '/_ovia';
$rows = [];
$add = function (string $label, ?bool $ok, string $detail = '') use (&$rows) { $rows[] = [$label, $ok, $detail]; };

$add('PHP 8.1 ou plus récent', PHP_VERSION_ID >= 80100, 'Version : ' . PHP_VERSION . (PHP_VERSION_ID >= 80100 ? '' : ' — change la version dans DirectAdmin → Sélecteur de version PHP'));
$add('Stockage sans base de données (pdo_sqlite)', extension_loaded('pdo_sqlite'), extension_loaded('pdo_sqlite') ? '' : 'Indispensable tant qu\'aucune base MySQL n\'est branchée.');
$add('Connexion MySQL possible plus tard (pdo_mysql)', extension_loaded('pdo_mysql') ?: null, 'Facultatif : seulement pour basculer vers une base MySQL.');
$add('Traitement des photos (gd)', extension_loaded('gd') ?: null, extension_loaded('gd') ? '' : 'Sans GD, les photos sont gardées telles quelles (non allégées).');
$add('Chiffrement (sodium ou openssl)', extension_loaded('sodium') || extension_loaded('openssl'));
$add('Appels sortants paiement / IA (curl)', extension_loaded('curl') || (bool) ini_get('allow_url_fopen'));
$add('Texte international (mbstring)', extension_loaded('mbstring'));
$writable = is_dir($priv) && is_writable($priv);
$add('Dossier privé _ovia inscriptible', $writable, $writable ? '' : 'Donne les droits d\'écriture (755) au dossier _ovia.');
$add('Fonction mail() disponible', function_exists('mail') ?: null, 'Sinon, renseigne un compte SMTP dans l\'app : Admin → Réglages.');

// Le dossier privé doit être invisible depuis Internet.
$https = (($_SERVER['HTTPS'] ?? '') !== '' && $_SERVER['HTTPS'] !== 'off') || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
$base = ($https ? 'https' : 'http') . '://' . preg_replace('/[^A-Za-z0-9.:\-]/', '', (string) ($_SERVER['HTTP_HOST'] ?? 'localhost')) . rtrim(dirname($_SERVER['SCRIPT_NAME'] ?? '/'), '/');
$fetch = function (string $url): array {
    $ctx = stream_context_create(['http' => ['timeout' => 8, 'ignore_errors' => true], 'ssl' => ['verify_peer' => false, 'verify_peer_name' => false]]);
    $body = @file_get_contents($url, false, $ctx);
    $code = 0;
    foreach ($http_response_header ?? [] as $h) if (preg_match('#^HTTP/\S+\s+(\d{3})#', $h, $m)) $code = (int) $m[1];
    return [$code, (string) $body];
};
[$code] = $fetch("$base/_ovia/src/Core.php");
$add('Dossier privé protégé (.htaccess actif)', $code === 0 ? null : in_array($code, [403, 404], true), $code === 0 ? 'Test impossible depuis le serveur lui-même : ouvre ' . htmlspecialchars("$base/_ovia/src/Core.php") . ' — tu dois voir « Accès interdit ».' : "Réponse du serveur : $code" . (in_array($code, [403, 404], true) ? '' : ' — DANGER : le fichier .htaccess du dossier _ovia manque ou est ignoré.'));
[$code, $body] = $fetch("$base/api/health");
$add('API en ligne (/api/health)', $code === 0 ? null : ($code === 200 && str_contains($body, '"ok":true')), $code === 0 ? 'Ouvre ' . htmlspecialchars("$base/api/health") . ' : tu dois voir {"ok":true}.' : "Réponse : $code " . htmlspecialchars(substr($body, 0, 120)));
$add('HTTPS actif', $https, $https ? '' : 'Active le certificat Let\'s Encrypt du sous-domaine dans DirectAdmin → Certificats SSL.');
$add('Application web présente (index.html)', is_file(__DIR__ . '/index.html') ?: null, is_file(__DIR__ . '/index.html') ? '' : 'Le zip du serveur contient l\'app web ; vérifie que tout a bien été extrait.');
$bad = count(array_filter($rows, fn ($r) => $r[1] === false));
?><!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Contrôle Ovia</title>
<body style="font-family:system-ui,Segoe UI,sans-serif;background:#F4F5F7;color:#0E1116;margin:0;padding:24px">
<div style="max-width:680px;margin:auto"><h1 style="color:#2B3CF0;margin:0 0 4px">Ovia · contrôle de l'installation</h1>
<p style="color:#4A5260;margin:0 0 20px"><?= $bad ? "$bad point(s) à corriger." : 'Tout ce qui est indispensable est en place.' ?></p>
<?php foreach ($rows as [$label, $ok, $detail]): $c = $ok === true ? ['#0B6E4C', '#E3F5EC', 'OK'] : ($ok === false ? ['#B4213A', '#FBE9EC', 'À corriger'] : ['#9A4A06', '#FFF3E0', 'Info']); ?>
<div style="background:#fff;border-radius:14px;padding:14px 16px;margin-bottom:8px;display:flex;gap:12px;align-items:flex-start">
<span style="background:<?= $c[1] ?>;color:<?= $c[0] ?>;font-weight:700;font-size:12px;padding:4px 10px;border-radius:999px;white-space:nowrap"><?= $c[2] ?></span>
<div><div style="font-weight:600"><?= htmlspecialchars($label) ?></div><?php if ($detail): ?><div style="color:#4A5260;font-size:14px"><?= $detail ?></div><?php endif; ?></div></div>
<?php endforeach; ?>
<p style="color:#4A5260;font-size:13px;margin-top:20px">Quand tout est vert, tu peux supprimer ce fichier <code>verif.php</code>.</p></div></body></html>
