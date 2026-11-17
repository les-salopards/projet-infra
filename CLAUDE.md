# CLAUDE.md — contexte de reprise (projet-infra)

Fichier laissé par Raph à la fin de son travail sur `feat/authentik` (17/11/2026), pour que l'équipe et son Claude
reprennent la suite sans tout relire. À mettre à jour quand l'état du projet change.

## Le projet en bref
Projet M2 « Dev avec Docker » (groupe `les-salopards`). Deux dépôts :
- **ce dépôt (`projet-infra`)** : la stack Compose (Caddy, Authentik, Rallly, Mailpit, 2 Postgres) + config Authentik + docs ;
- **le fork Rallly** (https://github.com/les-salopards/rallly) : le code des features, image publiée sur GHCR.

Démarrage local, URLs, comptes de démo : [README.md](README.md). Détail Authentik : [docs/authentik.md](docs/authentik.md).

## État des branches de ce dépôt
| Branche | Contenu | État |
| --- | --- | --- |
| `main` | README + lien vers le fork | base |
| `feat/authentik` (celle-ci) | stack Compose complète, blueprint Authentik, docs SSO/policies/invitation, spec feature #1 + captures | **terminée, à merger dans `main` via PR** |
| `hardening/scan` | `docs/security.md`, `scripts/scan.sh`, workflow GitHub `security-scan.yml` (Trivy, hadolint, gitleaks) | pas mergée |
| `vm/deploy` | `deploy/bootstrap-vm.sh`, `deploy/deploy.sh`, `docs/vm.md` (VM Énov, VPN NetBird, sslip.io) | pas mergée |
| `docs/spec-group-restricted-poll` | spec de la feature libre (sondage réservé à un groupe Authentik) | pas mergée |

Le bloc `x-hardening` de `compose.yml` reprend déjà ce que préconise `docs/security.md`. Le blueprint
référence `docs/security.md`, qui n'existe qu'une fois `hardening/scan` mergée.

## Ce qui est fait sur `feat/authentik`
- **Stack** ([compose.yml](compose.yml)) : seul Caddy publie des ports (80/443) ; bases sur réseaux `internal` ;
  tous les services durcis (`cap_drop: ALL`, `no-new-privileges`, `read_only` quand possible, non-root).
- **TLS** : CA interne de Caddy (`tls internal`), pas d'IP publique ni en local ni sur la VM.
- **SSO Rallly ↔ Authentik (OIDC)** : connexion à Rallly uniquement via Authentik (`EMAIL_LOGIN_ENABLED=false`).
- **Policies par groupe** : `rallly-admins` (superuser Authentik) et `rallly-users` ont accès ; tout autre compte
  est refusé par Authentik, avant Rallly.
- **Invitation externe** : flow `rallly-invitation` (lien à usage unique → inscription → groupe `rallly-users`).
- **Comptes de démo** `alice` / `bob` / `charlie` créés par le blueprint.
- **Feature #1 (vote verrouillé par OAuth)** : code dans le fork, branche `feat/oauth-locked-vote` (construite sur
  `feat/group-restricted-poll`). Spec et preuves : [docs/specs/oauth-locked-vote.md](docs/specs/oauth-locked-vote.md).
  Activée par `OIDC_VOTE_REQUIRED=true` dans le compose.

## Règles du dépôt (à respecter)
- **Toute la config Authentik est déclarative** dans [authentik/blueprints/rallly.yaml](authentik/blueprints/rallly.yaml),
  appliquée par le worker au démarrage et à chaque modif. Ne rien configurer à la main dans l'admin Authentik :
  modifier le blueprint, puis vérifier Admin → Personnalisation → Blueprints → statut *successful*.
- **Secrets uniquement dans `.env`** (gitignoré). Jamais de valeur en dur dans le compose, le blueprint ou les docs.
  Les variables obligatoires sont en `${VAR:?voir .env.example}` : toute nouvelle variable va aussi dans `.env.example`.
- **Ne publier aucun autre port que 80/443.** Une nouvelle app passe par un bloc dans [caddy/Caddyfile](caddy/Caddyfile).
- **Même `compose.yml` en local et sur la VM** : seuls `.env` et `DOMAIN` changent.
- Docs et commits en français, style des commits : `type: description` (`infra:`, `authentik:`, `docs:`, `vm:`, `hardening:`).

## Pièges déjà rencontrés (ne pas les re-débugger)
- **Redirect URI** : Rallly (Better Auth) utilise `/api/auth/callback/oidc`. Elle est construite depuis `DOMAIN`
  dans le blueprint et doit correspondre exactement à `NEXT_PUBLIC_BASE_URL`.
- **Rallly appelle Authentik par son URL publique** (l'issuer doit être identique à celui vu par le navigateur) :
  alias réseau `auth.${DOMAIN}` sur Caddy + `NODE_EXTRA_CA_CERTS` alimenté par le service one-shot `caddy-ca`.
- **Si la discovery OIDC échoue au démarrage, Rallly désactive le provider en silence** (`Provider "oidc" ... skipped`
  dans ses logs) : d'où `depends_on: authentik-server: service_healthy`. Si le bouton Authentik n'apparaît pas :
  `docker compose restart rallly` une fois Authentik healthy.
- **Authentik 2026 exige `grant_types`** sur le provider, sinon « The request is otherwise malformed ».
- **`NODE_EXTRA_CA_CERTS` n'est lu qu'au lancement de Node** : la CA doit être copiée avant le démarrage de Rallly.
- Le worker Authentik tourne **sans root et sans `docker.sock`** (inutiles sans outpost Docker) : ne pas les remettre.

## Reste à faire (connu à ce jour)
1. **PR `feat/authentik` → `main`**, puis merger `hardening/scan`, `vm/deploy` et la spec de la feature libre
   (conflits probables sur `.gitignore` et sur la doc ; garder la version de `compose.yml` de `feat/authentik`).
2. **Image du fork** : par défaut `RALLLY_IMAGE` pointe sur l'image upstream `lukevella/rallly:4.17`, qui **ignore**
   `OIDC_VOTE_REQUIRED` et n'a pas la feature libre. Pour la démo, mettre `RALLLY_IMAGE=ghcr.io/les-salopards/rallly:<tag>`
   dans le `.env` (le tag dépend de la CI du fork).
3. **Feature libre (sondage réservé à un groupe)** : côté fork, branche `feat/group-restricted-poll` (porteur : La Tribe).
   La #1 en dépend déjà ; vérifier que les deux sont mergées dans la branche qui sert à construire l'image.
4. **Déploiement sur la VM Énov** : suivre `docs/vm.md` (branche `vm/deploy`). Sur la VM, `DOMAIN` = `<IP-avec-tirets>.sslip.io`.
5. **Points de `docs/security.md` encore « à valider dans la stack complète »** (Authentik et Rallly) : les mettre
   à jour maintenant que la stack tourne.
6. Limite connue de la #1 : un même compte peut ajouter plusieurs réponses. Piste : refuser une 2e réponse du même
   `userId` dans `addParticipantAction` (fork).

## Vérifier que tout marche
```sh
docker compose config --quiet                 # le .env est complet
docker compose up -d --wait                   # ~2 min la 1re fois
docker compose ps                             # tout healthy, caddy-ca en "exited (0)"
docker compose logs rallly | grep -i oidc     # pas de "Provider ... skipped"
```
Puis les scénarios de démo de [docs/authentik.md](docs/authentik.md) (SSO alice, refus charlie, invitation) et de
[docs/specs/oauth-locked-vote.md](docs/specs/oauth-locked-vote.md) (avec l'image du fork).
