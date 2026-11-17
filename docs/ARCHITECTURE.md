# Ovia — Architecture

> Nom de l'application : **Ovia** (logo fourni par Edimo Paul Cyrille, intégré dans `app/assets/`).
> Les valeurs entre crochets sont des **décisions business non prises** : rien n'a été inventé.

---

## 1. Hypothèses

| Sujet | Hypothèse retenue | À confirmer par toi |
|---|---|---|
| Pays de lancement | Cameroun d'abord (XAF, +237), extensible zone CEMAC (même devise XAF) | [TARGET AFRICAN COUNTRIES] |
| Utilisateurs | Particuliers (acheteurs/vendeurs), commerçants, chauffeurs, administrateurs | — |
| Langue | Français d'abord, anglais en Phase 2 (Cameroun bilingue) | — |
| Réseau | 3G/4G instable → idempotence, reprises, images légères | — |
| Paiements | Notch Pay (Orange Money, MTN MoMo), testé en mode essai ; paiement à la remise en complément | Passage en mode réel |
| Frais acheteur | 5 % par défaut, modifiable dans Administration → Réglages | [BUYER FEE] |
| Codes de vérification | Par e-mail (obligatoire à l'inscription). Pas de SMS : aucun fournisseur SMS n'est requis | — |
| Données perso | Loi camerounaise n° 2024/017 du 23/12/2024 : autorisation préalable de l'Autorité de protection des données, registre des traitements, autorisation pour transfert hors du pays | Avis juridique local |
| Paiement / monnaie électronique | Réglementation CEMAC/COBAC/BEAC : la plateforme **ne détient pas** l'argent elle-même — c'est le prestataire agréé qui l'encaisse ; le séquestre est un **état comptable** chez nous | Avis juridique : statut exact du séquestre |
| Entité légale | — | [LEGAL ENTITY] |

## 2. Décisions techniques

**Application : Flutter**, une seule base de code pour Android, iOS, Windows et le web (le web sert aussi d'application installable sur iPhone tant que l'App Store n'est pas ouvert).

**Serveur : PHP 8.1+ sans dépendance**, dans `server/`. Pourquoi ce choix, après un premier serveur Node.js/PostgreSQL hébergé sur un PC :
- l'hébergement disponible est un mutualisé DirectAdmin : PHP y tourne en permanence, sans processus à surveiller ni tunnel ;
- l'adresse ne change plus (`https://oviaapp.itsscm.org`) et le serveur reste en ligne PC éteint ;
- aucune base n'est exigée au départ : les données vivent dans un fichier privé (SQLite), puis basculent vers MySQL sur simple saisie des accès. En MySQL, toutes les tables portent un préfixe (`ovia_` par défaut) : la base peut être partagée avec un autre site sans que ses tables soient touchées.

## 3. Architecture

```
 Android · iOS · Windows · Web (Flutter)
        │ HTTPS, JWT court + jeton de rafraîchissement rotatif
        ▼
 https://oviaapp.itsscm.org
   ├── index.html …            application web (même origine que l'API)
   ├── api/index.php           point d'entrée unique de l'API
   └── _ovia/  (privé)         src/ · config.php · data/ (fichier de données, photos, journal)
        │
        ├── Stockage : fichier SQLite  ──bascule automatique──▶  MySQL
        ├── Notch Pay (Orange Money, MTN MoMo) : clé publique + webhook signé
        ├── E-mail : SMTP ou mail() de l'hébergeur
        └── Gemini : assistant « Décrire avec l'IA »
```

### Modules du serveur (`server/public/_ovia/src`)

| Fichier | Rôle |
|---|---|
| `Core.php` | Erreurs métier, validation des entrées, chiffrement, appels HTTP sortants |
| `Db.php` | Schéma unique pour SQLite et MySQL, transactions, bascule fichier → MySQL |
| `App.php` | Configuration auto-générée, routeur, jetons, limitation de débit, réglages chiffrés |
| `Auth.php` | Inscription par e-mail + code, connexion, mot de passe oublié, sessions |
| `Market.php` | Annonces, photos ré-encodées, assistant IA |
| `Orders.php` | Grand livre, Notch Pay, commandes avec séquestre ou paiement à la remise |
| `Messaging.php` | Discussions d'annonce avec offres, discussions privées, groupes |
| `Services.php` | Notifications, retraits, covoiturage, VTC, restaurants et boutiques |
| `Admin.php` | Tableau de bord, utilisateurs, réglages, bascule MySQL, tâches de fond |

### Les trois façons de payer une commande

1. **Mobile Money direct** : l'acheteur saisit son numéro, reçoit la demande sur son téléphone et valide avec son code secret (jamais saisi dans l'application). L'argent est mis en séquestre.
2. **Page sécurisée du prestataire** : même résultat, via la page hébergée de Notch Pay.
3. **À la remise** : l'acheteur paie le vendeur de la main à la main. Sans frais, sans séquestre, donc sans protection acheteur — c'est dit clairement à l'écran.

### Flux de paiement en ligne (le cœur de la confiance)

1. `POST /orders` (avec `Idempotency-Key`) : l'annonce est verrouillée puis réservée dans la même transaction.
2. `POST /orders/:id/pay-mobile` ou `/pay` : le paiement est créé chez le prestataire.
3. Confirmation par webhook (signature HMAC sur le corps brut, anti-rejeu) **ou** par interrogation ; dans les deux cas le serveur **redemande l'état réel au prestataire** et compare montant et devise.
4. Écriture comptable `psp:clearing +total / escrow −total`, commande `paid`.
5. L'acheteur confirme la réception : `escrow +total / wallet:vendeur −prix / platform:revenue −frais`.
6. Litige → `disputed` ; un admin rembourse (`escrow +total / psp:clearing −total`) ou paie le vendeur.

### Comptes

- E-mail **obligatoire** et vérifié par code ; téléphone facultatif (utile pour Mobile Money et les livraisons).
- Connexion par e-mail ou téléphone. Mot de passe oublié : code par e-mail.
- L'accueil, la recherche, les fiches et les commerces sont visibles **sans compte** ; se connecter n'est demandé qu'au moment d'agir.

## 4. Design system « Clarté européenne »

Le canevas de design (écrans + composants) fait référence. Les jetons sont codés dans `app/lib/core/theme/tokens.dart`.

| Jeton | Valeur | Usage |
|---|---|---|
| Bleu Ovia | `#2B3CF0` | **Seule** couleur d'action |
| Bleu brume | `#EBEDFF` | Sélection |
| Citron | `#D4F34A` | Avantage / nouveauté, jamais un bouton |
| Encre | `#0E1116` | Texte |
| Ardoise | `#4A5260` | Texte secondaire (7,6:1) |
| Brume | `#F4F5F7` | Fond |
| Titres | Bricolage Grotesque 700 | 24–34 px |
| Texte | Inter 400/600 | 13–17 px |
| Rayons | 12 / 14 / 20 / 999 | Cartes / champs / panneaux / pilules |
| Espacement | 4 · 8 · 12 · 16 · 24 · 32 | Cibles tactiles ≥ 44 px |

Inspirations, sans copie :
- **Vinted** : grille photo 2 colonnes, prix sous la photo.
- **BlaBlaCar** : frise horaire des trajets.
- **Kayak** : prix par date, tri Meilleur / Moins cher / Plus rapide.

Mise en page adaptative : barre basse sur téléphone, rail latéral à partir de 1024 px (Windows, web sur ordinateur).
