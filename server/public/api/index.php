<?php
// Point d'entrée unique de l'API Ovia. Tout le code vit dans le dossier privé _ovia.
declare(strict_types=1);
require dirname(__DIR__) . '/_ovia/src/bootstrap.php';
Ovia\App::run();
