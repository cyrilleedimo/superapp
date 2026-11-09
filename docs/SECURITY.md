# Sécurité — ce qui est en place, ce qui reste

Référentiels suivis : OWASP ASVS 4 (niveau 2 visé), OWASP MASVS (mobile), PCI-DSS (périmètre réduit grâce au paiement hébergé).

## En place (Phase 1, testé)

| Domaine | Mesure | Où |
|---|---|---|
| Mots de passe | argon2id (m=19 Mio, t=2, p=1 — recommandation OWASP), 10 caractères min. | `auth/service.ts` |
| Énumération de comptes | Temps de réponse égalisé (hash factice) ; renvoi d'OTP muet | `auth/service.ts` |
| Force brute | Verrouillage 15 min après 5 échecs ; OTP bloqué après 5 essais ; 10 req/min sur `/auth/*`, 300/min global | `auth/*`, `app.ts` |
| Sessions | JWT HS256 de 15 min (algorithme imposé, `iss`/`aud` vérifiés) + refresh opaque haché, **rotation** et **révocation de toute la famille si réutilisation** (vol détecté) | `auth/tokens.ts`, `auth/service.ts` |
| Contrôle d'accès | Chaque ressource vérifie le propriétaire (404 plutôt que 403 pour ne rien révéler) ; rôle admin pour les remboursements | `orders/*`, `marketplace/*` |
| Validation | Zod sur toutes les entrées ; photos https seulement ; curseurs validés | partout |
| Injection SQL | Requêtes paramétrées uniquement | partout |
| Webhooks | HMAC-SHA256 sur le corps **brut**, comparaison à temps constant, anti-rejeu, **re-vérification serveur à serveur**, contrôle montant + devise | `payments/provider.ts`, `orders/service.ts` |
| Intégrité financière | Grand livre en partie double, ajout seul, équilibre vérifié par la base au COMMIT ; montants entiers | migration `001_init.sql` |
| Double vente / double débit | Verrou de ligne + index unique partiel + clé d'idempotence | `orders/service.ts` |
| Données de carte / Mobile Money | Jamais saisies ni stockées par nous : page hébergée du prestataire | `checkout_screen.dart` |
| En-têtes HTTP | Helmet (HSTS, nosniff, frame-options…), CORS fermé par défaut | `app.ts` |
| Journaux | Masquage de l'en-tête Authorization et des signatures ; erreurs 500 sans détail | `app.ts` |
| Usurpation d'IP | `X-Forwarded-For` accepté seulement du nombre de proxys déclaré | `TRUST_PROXY_HOPS` |
| Configuration | Démarrage refusé si secret trop court, fournisseur « sandbox » en production ou SMS absent | `config.ts`, `server.ts` |
| App | Jetons dans Keystore Android / DPAPI Windows ; https obligatoire en release ; `allowBackup=false` ; http autorisé en DEBUG uniquement | `token_store.dart`, `config.dart`, `tool/setup.ps1` |

## Reste à faire avant la production (bloquant)

1. **Fournisseur SMS** réel + limitation par numéro.
2. **Avis juridique** :
   - loi 2024/017 (autorisation préalable, registre des traitements, hébergement / transferts) ;
   - statut du séquestre au regard de la réglementation CEMAC.
3. **Secrets** dans un coffre (pas de `.env` en production) et rotation de `JWT_SECRET`.
4. **Pentest externe** avant le lancement et programme de signalement de vulnérabilités.
5. **Anti-fraude** : vélocité des paiements par compte et par appareil, KYC vendeurs au-delà d'un seuil [KYC THRESHOLD], liste de blocage.
6. **Sauvegardes** PostgreSQL chiffrées, avec test de restauration.
7. **Attestation d'intégrité de l'app** (Play Integrity) et certificate pinning, à évaluer.
8. **Expiration automatique** des commandes impayées (tâche planifiée) et libération automatique du séquestre après [AUTO-RELEASE DAYS] jours.
