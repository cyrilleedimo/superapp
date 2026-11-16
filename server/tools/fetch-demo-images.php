<?php
// Télécharge les photos des annonces d'exemple dans le paquet serveur (lancé par la compilation
// automatique). Ainsi le serveur n'a besoin d'aucun accès sortant pour les installer.
declare(strict_types=1);
$dir = dirname(__DIR__) . '/public/_ovia/demo';
@mkdir("$dir/img", 0755, true);
$ok = 0;
$items = json_decode((string) file_get_contents("$dir/annonces.json"), true);
foreach ($items as $it) {
    $ch = curl_init($it['image']);
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_FOLLOWLOCATION => true, CURLOPT_TIMEOUT => 60,
        CURLOPT_USERAGENT => 'OviaDemoImages/1.0 (https://github.com/cyrilleedimo/superapp)']);
    $data = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    if ($code === 200 && is_string($data) && @getimagesizefromstring($data)) {
        file_put_contents("$dir/img/{$it['key']}.img", $data);
        $ok++;
    } else {
        fwrite(STDERR, "non téléchargée ($code) : {$it['key']}\n");
    }
    usleep(400000);
}
echo "$ok / " . count($items) . " photos d'exemple téléchargées\n";
