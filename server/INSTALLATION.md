# Installer le serveur Ovia sur l'hébergeur (DirectAdmin)

Le serveur tient dans **un seul zip** : l'API (PHP) et l'application web. Aucune base de données
n'est nécessaire pour démarrer. Compte 10 minutes.

## 1. Créer l'adresse
1. DirectAdmin → **Gestion des sous-domaines** → ajoute `app` → l'adresse sera `https://app.itsscm.org`.
2. DirectAdmin → **Certificats SSL** → **Let's Encrypt** → coche `app.itsscm.org` → enregistre. Attends quelques minutes.
3. DirectAdmin → **Sélecteur de version PHP** → **8.1 ou plus récent** pour ce sous-domaine.

> Une autre adresse que `app.itsscm.org` ? C'est possible : modifie ensuite la ligne `apiUrl`
> du fichier `server.json` à la racine du dépôt GitHub. Les applications déjà installées suivront.

## 2. Déposer les fichiers
1. **Gestionnaire de fichiers** → ouvre le dossier du sous-domaine (`domains/app.itsscm.org/public_html`).
   S'il contient un `index.html` par défaut de l'hébergeur, supprime-le.
2. **Envoyer** `Ovia-serveur-x.y.z.zip` → clic droit → **Extraire** ici.
3. **Supprime le zip** du dossier.
4. Vérifie que tu vois : `index.html`, `.htaccess`, le dossier `api`, le dossier `_ovia`.
   (Les fichiers qui commencent par un point sont parfois masqués : active « Afficher les fichiers cachés ».)

## 3. Reprendre les comptes existants (une seule fois)
Dépose le fichier **`comptes-importes.json`** (reçu à part, jamais publié) dans le dossier **`_ovia`**.
Au premier appel, le serveur crée les comptes et les réglages qu'il contient, puis **supprime le fichier**.

Un compte du fichier peut porter un **mot de passe provisoire** (`temp_password`) et un e-mail déjà connu
(`email`, `email_verified`). Le provisoire n'ouvre aucune session : à la première connexion, l'application
demande de choisir le vrai mot de passe (8 caractères minimum), puis le provisoire cesse de fonctionner.
Connecte-toi donc **tout de suite après l'installation**, avant de donner l'adresse à qui que ce soit.

## 4. Vérifier
Ouvre `https://app.itsscm.org/verif.php` : tout ce qui est indispensable doit être vert.
Ensuite, supprime `verif.php`.

## 5. Premier lancement
- Ouvre `https://app.itsscm.org` (ou l'application Android / Windows).
- Les comptes repris se connectent avec **leur numéro et leur ancien mot de passe**, puis ajoutent leur e-mail.
- Sans fichier de reprise : le **premier compte créé** devient l'administrateur.

## 6. Réglages (dans l'application : Profil → Administration → Réglages)
| Réglage | Quoi mettre |
|---|---|
| Notch Pay — clé publique | la clé qui commence par `pk_test.` (essais) puis `pk.` (réel). **Jamais la clé secrète.** |
| Notch Pay — clé de signature | la clé qui commence par `hsk_` |
| Paiement en ligne | « Notch Pay » |
| E-mails | idéalement un compte créé dans DirectAdmin (ex. `no-reply@itsscm.org`) : serveur `mail.itsscm.org`, port 465, SSL. Puis « Tester l'envoi d'e-mail ». |
| Courses en ville | prise en charge et prix au km (0 = service fermé) |
| Clé Google AI Studio | pour « Décrire avec l'IA » |

Dans le tableau de bord Notch Pay, colle comme **adresse de webhook** celle affichée en haut de l'onglet Réglages
(`https://app.itsscm.org/api/webhooks/payments`).

## Annonces d'exemple
Au premier lancement, 13 annonces d'exemple (photos libres de droits, licence CC0) s'installent toutes seules pour que
l'accueil ne soit pas vide. Elles portent la mention « Exemple », seul un administrateur peut les commander (pour simuler),
et elles sont **retirées automatiquement** dès que 20 vraies annonces ont été publiées (seuil modifiable dans Réglages,
où un bouton permet aussi de les retirer ou de les remettre à la main).

## 7. Brancher une base MySQL (même si elle contient déjà autre chose)
Administration → Réglages → **Brancher MySQL**, saisis le serveur, le nom de la base, l'utilisateur et le mot de passe.

- **La base peut être partagée** avec un autre site. Ovia n'y crée que ses propres tables, toutes préfixées
  (`ovia_users`, `ovia_orders`…). Il ne modifie, ne vide et ne supprime aucune autre table.
- Avant d'enregistrer quoi que ce soit, le serveur vérifie la connexion, vérifie qu'aucune table existante ne porte
  déjà un de ses noms, puis crée ses tables. Si une étape échoue, **rien ne change** et tu restes sur le fichier.
- Ensuite il recopie les données du fichier vers la base, compare le nombre de lignes, puis supprime le fichier.
- Le préfixe est modifiable dans la fenêtre (par défaut `ovia_`).
- L'utilisateur MySQL doit avoir le droit de créer des tables dans cette base.

`_ovia/schema.mysql.sql` recrée les mêmes tables à la main (phpMyAdmin → Importer) si tu préfères. Fais quand même
une **exportation de ta base dans phpMyAdmin avant** : c'est la seule vraie assurance, quel que soit le logiciel.

## 8. Mettre à jour
Envoie le nouveau zip et extrais-le par-dessus. `_ovia/config.php` et `_ovia/data/` ne sont pas dans le zip :
tes comptes, photos et réglages restent en place.

## 9. Sauvegarder
Télécharge régulièrement `_ovia/config.php` (les clés du serveur) et le dossier `_ovia/data/` (comptes, commandes, photos).
Sans `config.php`, les réglages chiffrés et les messages deviennent illisibles.

## Ce que contient `_ovia` (privé, inaccessible depuis Internet)
- `src/` : le code ; `config.php` : clés générées au premier lancement ; `data/` : données, photos, journal `erreurs.log` ;
- `cron.php` : tâche planifiée facultative (les tâches tournent déjà au fil des visites).
