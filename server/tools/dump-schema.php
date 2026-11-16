<?php
// Génère schema.mysql.sql : le fichier qui recrée toute la base MySQL d'Ovia à la main
// (phpMyAdmin → Importer). En temps normal ce n'est pas nécessaire : le serveur crée
// lui-même les tables dès que les accès MySQL sont renseignés.
declare(strict_types=1);
require dirname(__DIR__) . '/public/_ovia/src/Core.php';
require dirname(__DIR__) . '/public/_ovia/src/Db.php';
$tail = ' ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci';
$map = ['{AUTO}' => 'BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY', '{DT}' => 'DATETIME', '{TAIL}' => $tail];
$out = "-- Ovia — schéma MySQL / MariaDB (généré par tools/dump-schema.php, ne pas modifier à la main)\n"
     . "-- Import : phpMyAdmin → ta base → Importer. Le serveur sait aussi créer ces tables tout seul.\nSET NAMES utf8mb4;\n\n";
$out .= "CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(40) NOT NULL PRIMARY KEY, applied_at DATETIME NOT NULL)$tail;\n\n";
foreach (Ovia\Db::migrations() as $version => $statements) {
    $out .= "-- ---- $version\n";
    foreach ($statements as $sql) $out .= preg_replace('/\n\s+/', "\n  ", strtr($sql, $map)) . ";\n";
    $out .= "INSERT IGNORE INTO schema_migrations (version, applied_at) VALUES ('$version', UTC_TIMESTAMP());\n\n";
}
$out .= "-- Comptes du grand livre\n";
foreach (['escrow' => 'liability', 'psp:clearing' => 'asset', 'platform:revenue' => 'revenue', 'payouts:pending' => 'liability'] as $code => $kind) {
    $out .= "INSERT IGNORE INTO ledger_accounts (id, code, kind, created_at) VALUES (UUID(), '$code', '$kind', UTC_TIMESTAMP());\n";
}
file_put_contents(dirname(__DIR__) . '/public/_ovia/schema.mysql.sql', $out);
echo "schema.mysql.sql écrit (" . substr_count($out, 'CREATE TABLE') . " tables)\n";
