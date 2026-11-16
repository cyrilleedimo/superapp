<?php
// Chargement de l'API Ovia. Aucune dépendance externe : PHP 8.1+ suffit.
declare(strict_types=1);

if (PHP_VERSION_ID < 80100) {
    http_response_code(503);
    header('Content-Type: application/json');
    exit('{"error":"php_too_old","message":"PHP 8.1 ou plus récent est requis."}');
}
error_reporting(E_ALL);
ini_set('display_errors', '0');
ini_set('log_errors', '1');
mb_internal_encoding('UTF-8');
date_default_timezone_set('UTC');

foreach (['Core', 'Db', 'App', 'Mailer', 'Auth', 'Orders', 'Market', 'Messaging', 'Services', 'Admin'] as $f) {
    require __DIR__ . "/$f.php";
}
// Les erreurs PHP sont consignées dans un journal privé du dossier data/ (jamais affichées).
set_error_handler(static function (int $no, string $msg, string $file, int $line): bool {
    if (!(error_reporting() & $no)) return false;
    if ($no & (E_DEPRECATED | E_USER_DEPRECATED | E_NOTICE | E_USER_NOTICE)) return false; // consigné, sans interrompre
    throw new \ErrorException($msg, 0, $no, $file, $line);
});
@ini_set('error_log', dirname(__DIR__) . '/data/erreurs.log');

Ovia\App::route('GET', '/health', fn () => ['ok' => true]);
Ovia\Auth::routes();
Ovia\Market::routes();
Ovia\Orders::routes();
Ovia\Messaging::routes();
Ovia\Services::routes();
Ovia\Admin::routes();
