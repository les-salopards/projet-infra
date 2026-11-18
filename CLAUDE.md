# CLAUDE.md — contexte de reprise (projet-infra)

Fichier laissé par Raph le 17/11/2026, mis à jour par César le 18/11/2026 (veille de la soutenance), pour que l'équipe
et son Claude reprennent la suite sans tout relire. À mettre à jour quand l'état du projet change.
Note de cadrage (équipe, rôles, features, jalons) : [docs/cadrage.md](docs/cadrage.md).

## Le projet en bref
Projet M2 « Dev avec Docker » (groupe `les-salopards`). Deux dépôts :
- **ce dépôt (`projet-infra`)** : la stack Compose (Caddy, Authentik, Rallly, Mailpit, 2 Postgres) + config Authentik + docs ;
- **le fork Rallly** (https://github.com/les-salopards/rallly) : le code des features, image publiée sur GHCR.

Démarrage local, URLs, comptes de démo : [README.md](README.md). Détail Authentik : [docs/authentik.md](docs/authentik.md).

## État au 18/11/2026
| Dépôt | `main` contient | CI sur `main` |
| --- | --- | --- |
| `projet-infra` | stack Compose complète et blueprint Authentik (PR #2), durcissement, scan, déploiement VM, README clonable, slides (PR #3) | `security-scan` verte |
| fork `rallly` | #1 vote verrouillé par OAuth, feature libre (sondage réservé à un groupe), #7 vue calendrier, image runner patchée, Next.js 16.4.1 | `image.yml` verte : lint, tests, build, push GHCR, scan |

- **Stack** ([compose.yml](compose.yml)) : seul Caddy publie des ports (80/443) ; bases sur réseaux `internal` ;
  tous les services durcis (`cap_drop: ALL`, `no-new-privileges`, `read_only`, non-root) ; `scripts/check-compose.py`
  le vérifie en CI.
- **TLS** : CA interne de Caddy (`tls internal`), pas d'IP publique ni en local ni sur la VM.
- **Authentik** : SSO OIDC vers Rallly (`EMAIL_LOGIN_ENABLED=false`), policies `rallly-admins` / `rallly-users`
  (tout autre compte refusé avant Rallly), invitation externe `rallly-invitation`, comptes `alice` / `bob` / `charlie`.
- **Features** (code dans le fork, specs ici) : [#1](docs/specs/oauth-locked-vote.md) (Raph, `OIDC_VOTE_REQUIRED=true`),
  [feature libre](docs/specs/group-restricted-poll.md) (La Tribe), [#7](docs/specs/calendar-vote-view.md) (César).
- **CI du fork** : [docs/specs/fork-ci.md](docs/specs/fork-ci.md). Image : `ghcr.io/les-salopards/rallly:latest`
  (et `sha-<commit>`), publiée à chaque merge sur `main` du fork.
- **Historique réécrit le 18/11** (Raph) pour retirer les trailers `Co-Authored-By` : ne jamais repousser une branche
  locale antérieure ; se remettre à jour par `git fetch` + `git reset --hard origin/main`.

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
- **Fork en local** : Node 24 obligatoire (`nvm use 24`, sinon `pnpm install` et le hook de pré-commit échouent) ;
  le type-check de `apps/web` demande `NODE_OPTIONS=--max-old-space-size=8192`.
- **Les Actions d'un fork ne tournent pas par défaut** : les workflows upstream du fork sont désactivés via l'API,
  seul `image.yml` est actif.
- **Login Authentik automatisé (Playwright)** : l'URL d'Authentik contient `rallly.localhost` dans `redirect_uri`,
  attendre le retour sur le *nom d'hôte* ; le champ mot de passe se redessine, attendre « Pas vous ? » avant de taper.

## Reste à faire (connu à ce jour)
1. **Rendre public le package GHCR `rallly`** (org `les-salopards` → Packages → rallly → Package settings →
   Change visibility → Public). Aujourd'hui un `docker pull` anonyme répond `unauthorized` : la VM ne peut pas tirer l'image.
2. **Déploiement sur la VM Énov** : [docs/vm.md](docs/vm.md), avec `RALLLY_IMAGE=ghcr.io/les-salopards/rallly:latest`.
   Accès formateur (VPN, URL, comptes de démo).
3. **Soutenance** : mettre à jour la colonne État de [docs/soutenance/slides.md](docs/soutenance/slides.md) (CI verte,
   #7, VM), données de démo sur la VM, répétition chronométrée.
4. Exception Trivy `libbrotli1` (Authentik) qui expire le 31/12/2026 : nouvelle image Authentik ou date repoussée.
5. Limite connue de la #1 : un même compte peut ajouter plusieurs réponses. Piste : refuser une 2e réponse du même
   `userId` dans `addParticipantAction` (fork).
6. Limites assumées de la #7 : voir la fin de [docs/specs/calendar-vote-view.md](docs/specs/calendar-vote-view.md).

## Vérifier que tout marche
```sh
docker compose config --quiet                 # le .env est complet
docker compose up -d --wait                   # ~2 min la 1re fois
docker compose ps                             # tout healthy, caddy-ca en "exited (0)"
docker compose logs rallly | grep -i oidc     # pas de "Provider ... skipped"
```
Puis les scénarios de démo de [docs/authentik.md](docs/authentik.md) (SSO alice, refus charlie, invitation) et de
[docs/specs/oauth-locked-vote.md](docs/specs/oauth-locked-vote.md) et [docs/specs/calendar-vote-view.md](docs/specs/calendar-vote-view.md)
(avec l'image du fork).
