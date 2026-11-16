<?php
// Tâche planifiée FACULTATIVE (les mêmes tâches tournent déjà au fil des visites).
// DirectAdmin → Tâches Cron, toutes les 5 minutes :
//   /usr/local/bin/php /home/UTILISATEUR/domains/SOUS-DOMAINE/public_html/_ovia/cron.php > /dev/null 2>&1
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
require __DIR__ . '/src/bootstrap.php';
Ovia\App::boot(__DIR__);
Ovia\Jobs::maybeRun(true);
