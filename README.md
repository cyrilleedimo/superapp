# Ovia

Super-app : seconde main, courses en ville, covoiturage, repas, boutiques, voyages.

| Dossier | Contenu |
|---|---|
| `app/` | Application Flutter : Android, iOS, Windows et web (une seule base de code) |
| `server/` | Serveur PHP 8.1+ sans dépendance, pour hébergement mutualisé (DirectAdmin, cPanel…) |
| `server.json` | Adresse de l'API lue par les applications au démarrage |
| `docs/` | Architecture et sécurité |

## Publier une version
Chaque envoi sur `main` lance la compilation (GitHub Actions) et publie une *Release* avec :
l'APK Android, l'installeur Windows, le paquet serveur (API + application web) et un build iOS non signé.

## Installer le serveur
Voir [`server/INSTALLATION.md`](server/INSTALLATION.md) : un zip à extraire dans le dossier du sous-domaine.
Aucune base de données n'est nécessaire au départ ; la bascule vers MySQL se fait depuis l'application.

## Tester le serveur en local
```
php server/tests/run.php        # 143 vérifications de bout en bout, données jetables
```

## Sécurité
Aucun secret dans ce dépôt ni dans l'application : les clés (paiement, e-mail, IA) se saisissent dans
Administration → Réglages et sont chiffrées sur le serveur. Voir `docs/SECURITY.md`.
