# Ovia — super-app — v1.0

Super-app : **seconde main** (messagerie, offres), **VTC**, **covoiturage**, **repas**, **boutiques locales**, **voyages**, le tout avec **paiement séquestre**, porte-monnaie, retraits Mobile Money et espace d'administration.
App **Flutter** (Windows + Android 12+) et API **Node.js/TypeScript + PostgreSQL**.

```
superapp/
├── backend/                 API (testée : 25 tests d'intégration sur PostgreSQL réel)
│   ├── db/migrations/       Schéma SQL (grand livre, contraintes, triggers)
│   ├── src/modules/         auth · marketplace · messaging · orders (séquestre) · payments · ledger
│   │                        media · carpool · rides (VTC) · stores (repas/boutiques) · travel · account
│   └── test/                Parcours complets (auth, achat, webhook, fraude)
├── app/                     App Flutter
│   ├── lib/core/            thème, API, sécurité, navigation adaptative
│   ├── lib/features/        accueil, explorer, fiche article, paiement, vendre, profil, auth
│   └── tool/setup.ps1       Génère les projets Windows/Android natifs
├── docs/ARCHITECTURE.md     Hypothèses, stack, architecture, données, design system
├── docs/SECURITY.md         Mesures en place et reste à faire
└── docker-compose.yml       PostgreSQL + API en local
```

## 1. Lancer le backend (Windows)

Prérequis : Node.js 22+, et soit Docker Desktop, soit PostgreSQL 16.

```powershell
cd backend
copy .env.example .env
# Dans .env, remplir :
#   JWT_SECRET    -> node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
#   BUYER_FEE_BPS -> ta décision (ex. 500 = 5 %)
npm install

# Option A : avec Docker (depuis la racine du projet)
cd ..; docker compose up --build

# Option B : PostgreSQL déjà installé (DATABASE_URL renseigné dans .env)
npm run dev
```

L'API écoute sur `http://localhost:8080` (`/health` doit répondre `{"ok":true}`).
En développement, les codes SMS s'affichent dans la console (`[SMS dev] …`).

### Tests

```powershell
# Nécessite une base vide dédiée aux tests (elle est EFFACÉE à chaque lancement)
$env:TEST_DATABASE_URL="postgres://superapp:superapp@localhost:5432/superapp_test"
npm test
```

## 2. Lancer l'app Flutter

Prérequis : Flutter stable (3.24+) et Visual Studio 2022 avec « Développement Desktop en C++ » (Windows).
Android Studio est nécessaire en plus pour Android.

```powershell
cd app
.\tool\setup.ps1 -Org "[com.votre-domaine]"   # une seule fois : crée windows/ et android/, minSdk 31
flutter test                                   # tests unitaires
flutter run -d windows                         # app Windows
flutter run -d emulator-5554                   # émulateur Android (API http://10.0.2.2:8080)
```

## 3. Construire les livrables

```powershell
# Windows : exécutable + DLL dans build\windows\x64\runner\Release\
flutter build windows --release --dart-define=API_URL=https://api.[VOTRE-DOMAINE]

# Android 12+ : APK
flutter build apk --release --dart-define=API_URL=https://api.[VOTRE-DOMAINE]
# → build\app\outputs\flutter-apk\app-release.apk
```

Pour publier sur le Play Store, il faut d'abord **signer** l'APK/AAB avec ta propre clé (guide Flutter « Build and release an Android app »).
Pour distribuer sur Windows, il faut emballer l'exécutable : MSIX (`msix` sur pub.dev) ou un installeur Inno Setup.

En release, l'app **refuse** une `API_URL` en `http://`.

## 4. Activer un vrai prestataire de paiement

Dans `backend/.env` :

```
PAYMENT_PROVIDER=notchpay
NOTCHPAY_API_KEY=...          # clé de test d'abord
NOTCHPAY_WEBHOOK_HASH=...     # « Hash Key » du webhook (≠ clé API)
```

Puis déclarer l'URL `https://api.[VOTRE-DOMAINE]/webhooks/payments` dans le tableau de bord du prestataire.
Un autre prestataire s'ajoute en implémentant l'interface `PaymentProvider` (`src/modules/payments/provider.ts`).

## 5. Obtenir l'APK et l'installeur Windows sans rien installer

Chaque envoi sur `main` déclenche **GitHub Actions** (`.github/workflows/build.yml`) :
tests du backend → APK Android 12+ → installeur Windows `Ovia-Setup-x.y.z.exe` → **Release** GitHub.
Télécharge les fichiers dans l'onglet **Releases** du dépôt.

## 6. Mettre le serveur en ligne

L'app a besoin du serveur pour fonctionner. Le plus simple est Render : **New → Blueprint →** ce dépôt (`render.yaml`).
Copie ensuite l'adresse https obtenue dans l'app : écran de connexion → **Serveur**.
Tu peux aussi la mettre dans la variable de dépôt `API_URL` pour qu'elle soit intégrée aux prochaines compilations.

## 7. Feuille de route

| Phase | Contenu |
|---|---|
| **1 — livrée** | Identité sécurisée, seconde main, séquestre, paiements, grand livre |
| **2 — livrée** | Photos (ré-encodées, EXIF supprimé), messagerie et offres, notifications in-app, retraits Mobile Money (validés par admin), expiration et libération automatiques, administration, **VTC** (chauffeurs vérifiés, carte, estimation, attribution), **covoiturage** |
| **3 — livrée** | **Repas** et **Boutiques locales** (catalogue, stock, panier, suivi de livraison), **Voyages** (écran et API prêts, données via [TRAVEL API PARTNER]) |
| 4 — à venir | Notifications push ([PUSH PROVIDER]), paiement in-app des courses VTC (pré-autorisation), livreurs indépendants, anglais, colis |
| Avant lancement | Voir `docs/SECURITY.md` — reste à faire |
