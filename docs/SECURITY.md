# Ovia — Sécurité : ce qui est en place, ce qui reste

Références suivies : OWASP ASVS 4 (niveau 2 visé), OWASP MASVS (mobile), PCI-DSS (périmètre réduit : aucune donnée de carte ni code Mobile Money ne passe par nous).

## En place (vérifié par `php server/tests/run.php`, 143 contrôles)

| Domaine | Mesure | Où |
|---|---|---|
| Mots de passe | argon2id (m=19 Mio, t=2, p=1) si PHP le propose, sinon bcrypt coût 12 ; 8 caractères min. ; jamais stockés ni journalisés en clair | `Core.php` (Crypto), `Auth.php` |
| Vérification d'identité | E-mail obligatoire, code à 6 chiffres (haché HMAC, 10 min, 5 essais), renvoi limité à 1/min | `Auth.php` |
| Mot de passe oublié | Code par e-mail, réponse identique que le compte existe ou non, toutes les sessions révoquées après changement | `Auth.php` |
| Force brute | Verrouillage 15 min après 5 échecs ; 10 req/min sur les routes d'authentification, 300/min par adresse | `Auth.php`, `App::limit` |
| Sessions | JWT HS256 de 15 min (algorithme imposé, `iss`/`aud`/`exp` vérifiés) + jeton de rafraîchissement opaque haché, **rotation**, **révocation de toute la famille si réutilisation** | `App.php` (Jwt), `Auth.php` |
| Contrôle d'accès | Chaque ressource vérifie son propriétaire (404 plutôt que 403) ; rôle admin pour remboursements, réglages, utilisateurs | toutes les routes |
| Opérations sensibles | Retrait d'argent : mot de passe redemandé | `Services.php`, `Auth::requirePassword` |
| Validation | Toute entrée passe par `In` (types, bornes, listes fermées, champs inconnus refusés) | `Core.php` |
| Injection SQL | Requêtes préparées uniquement | `Db.php` |
| Paiement | Clé **publique** Notch Pay seulement (la clé privée n'est jamais demandée) ; webhook signé HMAC-SHA256 sur le corps brut, anti-rejeu, **re-vérification serveur à serveur**, contrôle montant + devise | `Orders.php` |
| Intégrité financière | Grand livre en partie double, écritures équilibrées, montants entiers ; verrou par utilisateur sur les retraits | `Orders.php` (Ledger) |
| Double vente | Article réservé dans la même transaction que la commande + clé d'idempotence | `Orders.php` |
| Secrets | `config.php` généré au premier lancement (clés aléatoires) ; clés de paiement / e-mail / IA **chiffrées en base** (libsodium ou AES-256-GCM), masquées dans l'admin | `App.php` (Settings) |
| Messages | Chiffrés au repos sur le serveur, HTTPS en transit. Pas de chiffrement de bout en bout (choix assumé : arbitrage des litiges, lutte contre les arnaques) | `Messaging.php` |
| Photos | Signature binaire vérifiée, image ré-encodée (EXIF/GPS supprimés), 5 Mo et 20 Mpx max, noms aléatoires | `Market.php` |
| Fichiers privés | Tout le code, la configuration et les données vivent dans `_ovia/`, interdit par `.htaccess` ; nom du fichier de données aléatoire | `server/public/_ovia/.htaccess` |
| Transport | Redirection HTTPS, HSTS, `nosniff`, `X-Frame-Options: DENY` | `server/public/.htaccess` |
| Erreurs | Aucun détail interne renvoyé au client ; tout 5xx est journalisé dans `_ovia/data/erreurs.log` | `App::run` |
| Application | Jetons dans Keystore Android / Trousseau iOS / DPAPI Windows ; https obligatoire en version finale ; aucun secret embarqué | `token_store.dart`, `config.dart` |

## Limites connues (dites clairement)

- **Hébergement mutualisé** : le serveur partage une machine avec d'autres sites. Convient au pilote ; au-delà de quelques milliers d'utilisateurs actifs, passer sur un serveur dédié (VPS) et sur MySQL/PostgreSQL.
- **Mode fichier (SQLite)** : une seule écriture à la fois. Suffisant pour démarrer ; brancher MySQL dès que l'hébergeur le permet.
- **Notifications** : dans l'application (pastille, rafraîchie toutes les 25 s) et par e-mail pour les événements importants. Pas de notification « push » quand l'application est fermée (nécessite un projet Firebase).
- **Appels audio/vidéo** : non proposés. Ils exigent un serveur relais (TURN) impossible sur un hébergement mutualisé.
- **Codes visibles par l'admin** (onglet E-mails) : pratique pour les essais, à désactiver avant l'ouverture au public (`pilot.show_codes`).

## Reste à faire avant l'ouverture au grand public

1. Passer Notch Pay en mode réel (clés `pk.` / `hsk.`) après vérification du compte marchand.
2. Compte e-mail dédié (SMTP) avec SPF/DKIM, pour que les codes n'arrivent pas en indésirables.
3. Avis juridique : loi camerounaise 2024/017 sur les données personnelles ; statut du séquestre au regard des règles CEMAC/COBAC.
4. Sauvegarde automatique de `_ovia/config.php` et `_ovia/data/`, avec test de restauration.
5. Anti-fraude : plafonds par compte, vérification d'identité des vendeurs au-delà d'un seuil.
6. Test d'intrusion externe.
7. Comptes développeur pour les boutiques : Google Play (25 $ une fois), Apple (99 $/an), Microsoft Store.
