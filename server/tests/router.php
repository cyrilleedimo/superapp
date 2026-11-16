<?php
// Routeur du serveur de développement PHP (php -S) : imite les règles .htaccess.
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if (str_starts_with($path, '/_ovia')) { http_response_code(403); exit('interdit'); }
if (str_starts_with($path, '/api/') || $path === '/api') { require __DIR__ . '/../public/api/index.php'; return true; }
return false;
