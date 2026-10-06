# J1 — Compose local démarrable

- **Date** : 2026-10-06
- **Porteur** : César
- **Références** : [note de cadrage](https://claude.ai/code/artifact/830575ec-211c-4244-ae00-1563011efb58), sujet §3.1, §3.3, §9 ; composes de référence : [rallly-selfhosted](https://github.com/lukevella/rallly-selfhosted) et [Authentik](https://goauthentik.io/docker-compose.yml)

## Objectif

Depuis un clone de `projet-infra`, les commandes `cp .env.example .env`, la génération des secrets et `docker compose up -d` doivent donner :
- Rallly, Authentik et Mailpit accessibles en HTTPS derrière un seul reverse proxy ;
- des mails capturés par un SMTP de lab ;
- le terrain prêt pour l'OIDC de J2, sans réglage réseau supplémentaire.

Les utilisateurs sont l'équipe (Raph part de cette base pour J2, La Tribe pour J3), puis le formateur.

## Décisions

| Sujet | Choix | Raison |
|---|---|---|
| Construction | Un seul `compose.yml` à nous, inspiré des deux composes upstream | Fichier lisible d'un bloc, écarts explicables ; un sous-module ou un `include:` obligerait à neutraliser Traefik, les profils et les ports publiés d'Authentik |
| Proxy / TLS | Caddy + `local_certs` (CA interne) | HTTPS en local comme sur la VM (qui n'a pas de domaine public), aucun outil à installer sur le poste |
| Bases | Deux Postgres (Rallly, Authentik) | Pas de script d'init, mises à jour indépendantes, environ 50 Mo de RAM en plus |
| Stockage S3 | Absent en J1 | Feature flag de Rallly (avatars, branding) dont aucune feature retenue n'a besoin ; il faudrait sinon une route `s3.${DOMAIN}` pour les URL présignées |
| Image Rallly | `lukevella/rallly` upstream, surchargeable par `RALLLY_IMAGE` | L'image custom GHCR arrive en J4 |

## Services

| Service | Image (tag par défaut, surchargeable dans `.env`) | Réseaux | Volumes | Ports hôte |
|---|---|---|---|---|
| `caddy` | `caddy:2.11.7-alpine` | `edge` (alias `rallly.${DOMAIN}`, `auth.${DOMAIN}`, `mail.${DOMAIN}`) | `caddy-data`, `caddy-config`, `./caddy/Caddyfile` (ro) | `80`, `443` |
| `caddy-ca` | même image que `caddy`, one-shot | aucun (`network_mode: none`) | `caddy-data` (ro), `caddy-ca` | aucun |
| `rallly` | `lukevella/rallly:4.15.4` | `edge`, `rallly-db` | `caddy-ca:/caddy-ca` (ro) | aucun |
| `rallly-db` | `postgres:18-alpine` | `rallly-db` | `rallly-db-data:/var/lib/postgresql` | aucun |
| `authentik-server` | `ghcr.io/goauthentik/server:2026.8.3`, `command: server` | `edge`, `authentik-db` | `authentik-data:/data`, `authentik-media:/media` | aucun |
| `authentik-worker` | même image, `command: worker` | `edge`, `authentik-db` | `authentik-data:/data`, `authentik-media:/media` | aucun |
| `authentik-db` | `postgres:16-alpine` (version de l'upstream Authentik) | `authentik-db` | `authentik-db-data:/var/lib/postgresql/data` | aucun |
| `mailpit` | `axllent/mailpit:v1.31.4` | `edge` | aucun : les mails sont perdus au redémarrage, c'est voulu | aucun |

**Réseaux**
- `edge` : bridge classique avec accès sortant (Rallly et Authentik peuvent avoir besoin de sortir, par exemple pour Gravatar ou la vérification de version).
- `rallly-db` et `authentik-db` : `internal: true`. Chaque base n'est joignable que par son application et n'a aucune route sortante.

**Démarrage**
- `caddy-ca` attend `caddy` en `service_healthy`.
- `rallly` attend `rallly-db` en `service_healthy` et `caddy-ca` en `service_completed_successfully`.
- `authentik-server` et `authentik-worker` attendent `authentik-db` en `service_healthy`.
- `restart: unless-stopped` partout, sauf `caddy-ca` (`restart: "no"`).

**Écarts avec le compose Authentik officiel, assumés**
- Pas de `docker.sock`, pas de `user: root` sur le worker : ils ne servent qu'aux outposts, dont on n'a pas besoin.
- Ports 9000/9443 non publiés.
- Volumes nommés à la place des bind mounts `./data`, `./certs` et `./custom-templates`. L'image contient un symlink `/data/media → /media`, qu'un volume nommé recopie : `/media` a donc son propre volume, sinon les médias envoyés (icônes d'applications) seraient perdus à la recréation du conteneur.

**Écarts avec rallly-selfhosted, assumés**
- Pas de Traefik, pas de profils `bundled-*`, pas de `rallly.sh`, pas de Garage.

## Noms d'hôte et TLS

- `DOMAIN=localhost` par défaut, ce qui donne `rallly.localhost`, `auth.localhost` et `mail.localhost`. Les navigateurs résolvent `*.localhost` vers 127.0.0.1, et WSL2 transmet ces ports à Windows.
- Caddyfile : un bloc global `local_certs` + `skip_install_trust`, puis un site par nom avec `reverse_proxy` vers `rallly:3000`, `authentik-server:9000` et `mailpit:8025`. La redirection HTTP → HTTPS est automatique.
- Healthcheck de Caddy : `test -f /data/caddy/pki/authorities/local/root.crt`.

**Contrainte OIDC (J2)** : Rallly doit joindre `https://auth.${DOMAIN}` depuis son conteneur avec la même URL que le navigateur.
- *Résolution* : les alias réseau de `caddy` sur `edge` font pointer les trois noms vers Caddy.
- *Confiance* : `NODE_EXTRA_CA_CERTS=/caddy-ca/root.crt`. Caddy écrit sa PKI en `0700`/`0600` (root), illisible pour l'utilisateur `nextjs` (uid 100) de Rallly, et `caddy-data` contient aussi la clé privée de la CA. Le service one-shot `caddy-ca` copie donc **seulement** `root.crt` (mode `0644`) dans le volume `caddy-ca`, monté en lecture seule dans Rallly. Node ne lit ce fichier qu'au démarrage, d'où la chaîne `caddy` healthy → `caddy-ca` terminé → `rallly`.
- Vérifié le 2026-10-06 par une sonde : depuis l'image Rallly, `auth.localhost` résout vers l'IP de Caddy et `fetch` réussit avec la CA ; sans elle, `UNABLE_TO_GET_ISSUER_CERT_LOCALLY`.

**Navigateur** : un avertissement de certificat s'affiche tant que la CA n'est pas importée. Le README explique comment la récupérer (`docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt`) et l'importer dans Windows (Autorités de certification racines de confiance) ou dans Firefox. `caddy-root.crt` est gitignoré.

## Configuration et secrets

`.env.example` est commité, `.env` est gitignoré. Les variables requises sont écrites `${VAR:?…}` dans le compose : un `.env` incomplet fait échouer `up` avec un message explicite.

| Variable | Requise | Défaut / génération | Utilisée par |
|---|---|---|---|
| `DOMAIN` | non | `localhost` | caddy, rallly |
| `RALLLY_IMAGE`, `AUTHENTIK_TAG`, `CADDY_TAG`, `MAILPIT_TAG` | non | tags de la table Services | tous |
| `RALLLY_SECRET_PASSWORD` | oui | `openssl rand -base64 32` | rallly (`SECRET_PASSWORD`) |
| `RALLLY_DB_PASSWORD` | oui | `openssl rand -hex 24` | rallly-db, rallly (`DATABASE_URL`) |
| `SUPPORT_EMAIL` | non | `support@lab.test` | rallly |
| `RALLLY_ADMIN_EMAIL` | non | `admin@lab.test` | rallly (`INITIAL_ADMIN_EMAIL`) |
| `AUTHENTIK_SECRET_KEY` | oui | `openssl rand -base64 60 \| tr -d '\n'` | authentik-server, authentik-worker |
| `AUTHENTIK_DB_PASSWORD` | oui | `openssl rand -hex 24` | authentik-db, authentik-server, authentik-worker |
| `AUTHENTIK_BOOTSTRAP_EMAIL` | non | `akadmin@lab.test` | authentik-server, authentik-worker (premier démarrage) |
| `AUTHENTIK_BOOTSTRAP_PASSWORD` | oui | `openssl rand -base64 18` | authentik-server, authentik-worker (premier démarrage) |
| `MAILPIT_UI_AUTH` | oui | `admin:<openssl rand -hex 12>` | mailpit (`MP_UI_AUTH`) |

**Valeurs fixées dans le compose (non secrètes)**
- Rallly : `NEXT_PUBLIC_BASE_URL=https://rallly.${DOMAIN}`, `SMTP_HOST=mailpit`, `SMTP_PORT=1025`, `SMTP_SECURE=false`, `NOREPLY_EMAIL=noreply@lab.test`.
- Authentik : `AUTHENTIK_EMAIL__HOST=mailpit`, `AUTHENTIK_EMAIL__PORT=1025`, `AUTHENTIK_EMAIL__USE_TLS=false`, `AUTHENTIK_EMAIL__FROM=authentik@lab.test`.

**Adresses en `@lab.test`** (TLD réservé, RFC 2606) : le formulaire de login de Rallly valide l'adresse avec `z.email()`, qui exige un TLD et refuse donc `@localhost`. Mailpit accepte tout.

**Pourquoi Mailpit est protégé** : lire Mailpit, c'est pouvoir se connecter à Rallly avec n'importe quel magic link. Son UI est donc sous basic auth en local comme sur la VM.

## Comptes de démarrage

- Authentik : le compte `akadmin` est créé au premier démarrage à partir des variables bootstrap, sans passer par le flow `initial-setup`. Changer ces variables ensuite n'a aucun effet : c'est à documenter dans le README.
- Rallly : l'admin se connecte par magic link, lu dans Mailpit à l'adresse `RALLLY_ADMIN_EMAIL`.

## Vérification

`scripts/smoke.sh` (bash + curl + docker, sans jq) s'arrête au premier échec et affiche ce qui a échoué :

1. `docker compose up -d --wait` : tous les services avec healthcheck sont healthy.
2. Ports publiés sur l'hôte = exactement {80, 443}, lus via `docker compose ps --format json`. Ce test prouve que les bases ne sont pas exposées.
3. CA extraite de Caddy, puis avec `curl --cacert` : `https://rallly.${DOMAIN}` → 2xx/3xx, `https://auth.${DOMAIN}/-/health/live/` → 2xx, `https://mail.${DOMAIN}/` → 401 sans identifiants et 200 avec.
4. Depuis le conteneur `rallly` : `node -e "fetch('https://auth.${DOMAIN}/-/health/live/')…"` réussit. C'est la preuve que les alias et la CA fonctionnent pour J2.
5. `ak test_email smoke@lab.test` dans `authentik-worker`, puis l'API Mailpit (`/api/v1/search?query=to:smoke@lab.test`) renvoie au moins un message.

**Parcours navigateur, après un smoke vert** : vérifié avec `/qa`.
- Le magic link Rallly arrive dans Mailpit et la connexion fonctionne.
- `akadmin` se connecte à Authentik.

**Critère de fin de J1** : smoke vert depuis un clone propre, parcours `/qa` OK, README à jour (démarrage, import de la CA, pièges rencontrés).

## Hors périmètre

- Configuration OIDC, groupes et invitation : J2.
- VM et `DOMAIN` réel : J3. À trancher alors : garder la CA interne ou passer à un vrai certificat.
- CI, scan d'images et image Rallly GHCR : J4.
- Durcissement poussé (`read_only`, `cap_drop`, `no-new-privileges`, utilisateur non-root vérifié par image) : volet de La Tribe. J1 se contente de ne pas l'empêcher (pas de socket Docker, pas de root ajouté).
- Garage / S3 : seulement si une feature en a besoin.

## Risques

- **Volume `caddy-data` supprimé** : nouvelle CA, à réimporter dans le navigateur, et redémarrage de Rallly nécessaire.
- **Healthchecks** : vérifié, aucun à écrire hormis Caddy et Postgres. Rallly (`curl …/api/status`), Mailpit (`/mailpit readyz`) et Authentik (`ak healthcheck`, `start_period` 120 s, donc un premier `up --wait` d'environ 2 min) en embarquent un.
- **WSL2 sans transfert localhost** (`localhostForwarding=false` ou mode réseau personnalisé) : `*.localhost` injoignable depuis Windows. Une ligne de diagnostic est prévue dans le README.
