# Super-app — Architecture (Phase 1)

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
| Paiements | Page de paiement **hébergée** par un agrégateur (Mobile Money + carte). Adaptateur Notch Pay écrit et vérifié sur sa doc ; architecture prête pour d'autres | [PAYMENT PROVIDERS] |
| Frais acheteur | Paramètre `BUYER_FEE_BPS` **sans valeur par défaut** | [BUYER FEE] |
| SMS (OTP) | Interface prête, fournisseur à choisir ; la prod refuse de démarrer sans | [SMS PROVIDER] |
| Données perso | Loi camerounaise n° 2024/017 du 23/12/2024 : autorisation préalable de l'Autorité de protection des données, registre des traitements, autorisation pour transfert hors du pays | Avis juridique local |
| Paiement / monnaie électronique | Réglementation CEMAC/COBAC/BEAC : la plateforme **ne détient pas** l'argent elle-même — c'est le prestataire agréé qui l'encaisse ; le séquestre est un **état comptable** chez nous | Avis juridique : statut exact du séquestre |
| Entité légale | — | [LEGAL ENTITY] |

## 2. Comparaison des stacks et décision

| Critère | **Flutter** (retenu) | React Native | Natif (Kotlin + WinUI/.NET) |
|---|---|---|---|
| Windows + Android, 1 code | Oui, officiel et stable | Android oui ; Windows via `react-native-windows` (Microsoft), écosystème plus mince | Non : 2 codes séparés |
| Fidélité au design sur mesure | Excellente (rendu propre, pixel-perfect) | Bonne, dépend des composants natifs | Excellente mais ×2 |
| Performances sur Android d'entrée de gamme | Bonnes (AOT) | Bonnes (nouvelle archi) | Les meilleures |
| Coût / vitesse pour une petite équipe | **Le plus bas** | Moyen | Le plus élevé |
| Stockage sécurisé | `flutter_secure_storage` (Keystore / DPAPI) | Équivalents | Natif |

**Décision : Flutter** pour l'app (une base de code, rendu identique Windows/Android, design européen sur mesure).
**Backend : Node.js 22 + TypeScript + Fastify + PostgreSQL 16**, monolithe modulaire. Pourquoi :
- Tu maîtrises déjà TypeScript/Node.
- PostgreSQL garantit les transactions ACID indispensables à l'argent, les contraintes et le plein texte français.
- Les modules se découpent en services le jour où le trafic l'exige. Commencer en microservices serait une erreur coûteuse.

## 3. Architecture

```
 ┌──────────────── Clients ────────────────┐
 │  App Windows (Flutter)   App Android 12+ │
 └──────────────┬───────────────────────────┘
                │ HTTPS (TLS 1.2+), JWT court + refresh rotatif
        ┌───────▼────────┐
        │ Répartiteur /  │  WAF, rate limit réseau, TLS
        │ reverse proxy  │
        └───────┬────────┘
        ┌───────▼──────────────────────────────────────────┐
        │ API Fastify (monolithe modulaire, sans état)      │
        │  auth │ marketplace │ orders+escrow │ payments    │
        │  ledger │ audit │ (Ph.2) rides │ food │ shops     │
        └──┬───────────────┬───────────────────┬───────────┘
           │               │                   │ HTTPS sortant
   ┌───────▼──────┐  ┌─────▼──────┐   ┌────────▼─────────────┐
   │ PostgreSQL 16│  │ (Ph.2)     │   │ Prestataire paiement │
   │ ACID, ledger │  │ Redis,     │   │ (page hébergée,      │
   │ append-only  │  │ stockage   │   │ Mobile Money, carte) │
   └──────────────┘  │ objets     │   └────────┬─────────────┘
                     └────────────┘            │ webhook signé HMAC
                                               ▼
                                   /webhooks/payments → resync serveur
```

### Flux de paiement séquestre (le cœur de la confiance)

1. `POST /orders` (avec `Idempotency-Key`) : l'annonce est verrouillée (`SELECT … FOR UPDATE`) puis réservée. Un index unique partiel interdit la double vente.
2. `POST /orders/:id/pay` : le paiement est créé chez le prestataire, l'app ouvre la page hébergée. **Aucune donnée de carte ni code Mobile Money ne transite par nous.**
3. Le webhook arrive, et on le traite dans cet ordre :
   - signature HMAC vérifiée sur le corps **brut** ;
   - anti-rejeu par empreinte SHA-256 du corps ;
   - **re-vérification serveur à serveur** du statut ;
   - contrôle **montant + devise** : en cas d'écart → `mismatch`, rien n'est crédité.
4. Une fois le paiement confirmé, l'écriture comptable est `psp:clearing +total / escrow −total` et la commande passe en `paid`.
5. L'acheteur confirme la réception. L'écriture est alors `escrow +total / wallet:vendeur −prix / platform:revenue −frais`.
6. Un litige passe la commande en `disputed`. Un admin peut ensuite rembourser : `escrow +total / psp:clearing −total`.

### Modèle de données (Phase 1)

| Table | Rôle | Garde-fous |
|---|---|---|
| `users` | Identité, rôle, statut, verrouillage | Téléphone E.164 unique (CHECK), argon2id |
| `otp_codes` | Codes SMS | Hash seul, 10 min, 5 essais max |
| `refresh_tokens` | Sessions | Hash seul, rotation, révocation de famille si réutilisation |
| `listings` | Annonces | Plein texte français (GIN), prix > 0 |
| `orders` | Commandes | `total = prix + frais` (CHECK), 1 commande vivante par annonce, idempotence |
| `payments` | Tentatives de paiement | Références uniques, statut `mismatch` |
| `webhook_events` | Anti-rejeu | Unicité (prestataire, SHA-256 du corps) |
| `ledger_accounts` / `ledger_entries` | Grand livre en partie double | **Ajout seul** (trigger) + **équilibre vérifié au COMMIT** (trigger différé) |
| `audit_log` | Traçabilité | Connexions, paiements, litiges, remboursements |

### API (Phase 1)

| Méthode | Route | Auth |
|---|---|---|
| POST | `/auth/register`, `/auth/verify-phone`, `/auth/login`, `/auth/refresh`, `/auth/logout`, `/auth/resend-otp` | publique, 10 req/min |
| GET | `/me`, `/me/wallet` | utilisateur |
| GET | `/listings` (q, category, city, minPrice, maxPrice, cursor), `/listings/:id` | publique |
| POST / PATCH / DELETE | `/listings`, `/listings/:id` | propriétaire |
| POST | `/orders`, `/orders/:id/pay`, `/orders/:id/confirm`, `/orders/:id/cancel`, `/orders/:id/dispute` | acheteur (ou vendeur pour cancel) |
| GET | `/orders`, `/orders/:id` | acheteur ou vendeur |
| POST | `/payments/:reference/refresh` | acheteur |
| POST | `/webhooks/payments` | signature HMAC |
| POST | `/admin/orders/:id/refund` | admin |

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

Mise en page adaptative : barre basse sur Android, rail latéral à partir de 1024 px (Windows).
