# J1 — Compose local démarrable : plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `cp .env.example .env` + génération des secrets + `docker compose up -d` doivent donner Rallly, Authentik et Mailpit en HTTPS derrière Caddy, avec des mails capturés et l'appel OIDC conteneur → `auth.${DOMAIN}` déjà fonctionnel pour J2.

**Architecture:** un seul `compose.yml` à la racine de `projet-infra`.
- Caddy est le seul service avec des ports publiés (80/443). Il sert ses propres certificats (`local_certs`) et porte les alias réseau `rallly.`, `auth.` et `mail.${DOMAIN}`.
- Un service one-shot `caddy-ca` copie uniquement le certificat racine public dans un volume monté en lecture seule dans Rallly (`NODE_EXTRA_CA_CERTS`).
- Chaque Postgres est sur son propre réseau `internal`.
- Un script `scripts/smoke.sh` (bash + curl + docker) sert de suite de tests. Il grossit tâche par tâche : test d'abord, puis service.

**Tech Stack:** Docker Compose v2+ (testé avec v5.6.0), `caddy:2.11.7-alpine`, `lukevella/rallly:4.15.4`, `postgres:18-alpine` (Rallly), `postgres:16-alpine` (Authentik), `ghcr.io/goauthentik/server:2026.8.3`, `axllent/mailpit:v1.31.4`.

**Spec:** `docs/specs/2026-10-06-j1-compose-local.md`

## Global Constraints

- **Commits** : ne jamais commiter ni pousser sans l'accord explicite de César. Les étapes « Commit » donnent le message à utiliser une fois l'accord obtenu ; sinon, laisser les fichiers en working tree et passer à la suite.
- Langue : README et docs en français ; code, identifiants, noms de services, commentaires et messages de commit en anglais.
- Ports publiés sur l'hôte : exactement `80` et `443`, sur le seul service `caddy`.
- Bases de données : aucune exposition. Réseaux `rallly-db` et `authentik-db` en `internal: true`.
- Secrets : uniquement dans `.env` (gitignoré). Chaque secret requis est écrit `${VAR:?message}` dans `compose.yml`. `.env.example` est commité avec les secrets vides.
- `DOMAIN` vaut `localhost` par défaut ; les hôtes sont `rallly.${DOMAIN}`, `auth.${DOMAIN}` et `mail.${DOMAIN}`.
- Adresses e-mail en `@lab.test` (le `z.email()` de Rallly refuse `@localhost`).
- Pas de `docker.sock` monté et pas de `user: root` ajouté, sur aucun service.
- Le worker Authentik n'est pas root. Le `/data` et le `/media` d'Authentik ont chacun leur volume nommé.
- Pas de Garage/S3, pas de Traefik, pas de `rallly.sh`.
- Le smoke ne dépend que de `bash`, `curl` et `docker` (`jq` n'est pas installé sur le poste de César).
- Le premier `up --wait` prend environ 2 min : le healthcheck d'Authentik a un `start_period` de 120 s. Utiliser `--wait-timeout 300`.

## Review Focus

1. **`.env` copié sans remplir les secrets** : `docker compose up` doit refuser de démarrer en nommant une variable manquante, au lieu de lancer Postgres avec un mot de passe vide. Test : contrôle `env guard` de la Task 1, sur `.env.example` tel quel.
2. **Base joignable hors de son réseau** : depuis `caddy` (sur `edge`), `rallly-db` et `authentik-db` ne doivent pas être résolus. Test : contrôles `isolation` des Tasks 2 et 3, avec un témoin positif sur `mailpit`.
3. **`down` puis `up` sans `-v`** (redémarrage du poste) : même CA, Rallly lui fait toujours confiance, et `akadmin` existe toujours. Test : contrôle de persistance de la Task 4 (empreinte de la CA avant/après, puis smoke complet).
4. **`DOMAIN` différent de `localhost`** (préparation de J3) : alias, Caddyfile et URL Rallly doivent suivre la variable. Test : smoke relancé avec `DOMAIN=lab.localhost` en Task 4.
5. **Mailpit sans identifiants** : l'UI **et** l'API (qui exposent les magic links) doivent répondre 401. Test : contrôles `mailpit` de la Task 1, sur `/` et `/api/v1/messages`.

---

## Structure des fichiers

| Fichier | Responsabilité | Créé en |
|---|---|---|
| `.gitignore` | exclut `.env`, `caddy-root.crt`, `.claude/settings.local.json` | Task 1 |
| `.env.example` | toutes les variables, secrets vides, commentaires de génération | Task 1 (complété en Tasks 2 et 3) |
| `compose.yml` | tous les services, réseaux et volumes | Task 1 (complété en Tasks 2 et 3) |
| `caddy/Caddyfile` | les 3 sites et la CA interne | Task 1 |
| `scripts/smoke.sh` | tests de bout en bout de la stack | Task 1 (complété en Tasks 2 et 3) |
| `README.md` | démarrage, comptes, import de la CA, architecture, écarts, pièges | Task 4 (remplace le README d'une ligne) |

---

### Task 1 : socle, proxy Caddy, CA et Mailpit

**Files:**
- Create: `.gitignore`, `.env.example`, `compose.yml`, `caddy/Caddyfile`, `scripts/smoke.sh`

**Interfaces:**
- Consumes : rien.
- Produces :
  - réseau `edge` ; volumes `caddy-data`, `caddy-config`, `caddy-ca` ; le fichier `/caddy-ca/root.crt` (0644) dans le volume `caddy-ca` ;
  - les services `caddy` (healthy quand la CA existe), `caddy-ca` (one-shot) et `mailpit` (SMTP `mailpit:1025`, UI `mailpit:8025`) ;
  - dans `scripts/smoke.sh`, les fonctions `ok <msg>`, `fail <msg>`, `val <VAR>`, `code <host> <path> [curl args…]` et `hairpin <url>` (cette dernière est définie ici, utilisée à partir de la Task 2), ainsi que les variables `DOMAIN`, `IP` et `CA`. Le script se termine par la ligne `echo "smoke: all checks passed"` : les tâches suivantes insèrent leurs blocs **juste avant** cette ligne.

- [ ] **Step 1 : écrire `.gitignore`**

```gitignore
.env
caddy-root.crt
.claude/settings.local.json
```

- [ ] **Step 2 : écrire le smoke test (version Task 1)**

`scripts/smoke.sh` :

```bash
#!/usr/bin/env bash
# End-to-end smoke test of the local stack. Run from anywhere: scripts/smoke.sh
# Needs a filled .env, plus bash, curl and docker only. Stops at the first failing check.
set -euo pipefail
cd "$(dirname "$0")/.."

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; exit 1; }
# Read VAR from .env without sourcing it (never execute .env as shell)
val()  { sed -n "s/^$1=//p" .env | tail -n 1; }

[ -f .env ] || fail "missing .env (cp .env.example .env, then generate the secrets, see README)"
DOMAIN=$(val DOMAIN); DOMAIN=${DOMAIN:-localhost}
IP=${SMOKE_IP:-127.0.0.1} # where caddy publishes 80/443
CA=$(mktemp); trap 'rm -f "$CA"' EXIT

# HTTP status of https://<host><path>, trusting Caddy's local CA
code() {
  local host=$1 path=$2; shift 2
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CA" \
    --resolve "$host:443:$IP" "$@" "https://$host$path"
}
# HTTPS request to <url> from inside the rallly container. Any HTTP answer passes:
# the check is DNS (network alias -> caddy) + TLS trust of Caddy's CA, both needed by OIDC in J2.
hairpin() {
  docker compose exec -T rallly node -e '
    fetch(process.argv[1]).catch(e => { console.error(e.cause?.code || e.message); process.exit(1) })' "$1"
}

echo "== env guard"
out=$(docker compose --env-file .env.example config -q 2>&1) \
  && fail "compose accepts .env.example with empty secrets"
grep -q "is missing a value" <<<"$out" || fail "unexpected compose error: $out"
ok "compose refuses empty secrets ($(grep -o 'required variable [A-Z_]*' <<<"$out" | head -n 1))"

echo "== stack up"
docker compose up -d --wait --wait-timeout 300 >/dev/null 2>&1 \
  || { docker compose ps -a; fail "docker compose up --wait"; }
ok "all services healthy"

echo "== exposure"
ports=$(docker compose ps --format '{{range .Publishers}}{{if .PublishedPort}}{{.PublishedPort}} {{end}}{{end}}' \
  | tr ' ' '\n' | grep . | sort -un | paste -sd, -)
[ "$ports" = "80,443" ] || fail "published host ports are '$ports', expected '80,443'"
ok "only 80,443 published"

docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt >"$CA"
grep -q "BEGIN CERTIFICATE" "$CA" || fail "could not read Caddy root CA"

c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "mail.$DOMAIN:80:$IP" "http://mail.$DOMAIN/")
[ "$c" = 308 ] || fail "http://mail.$DOMAIN -> $c, expected 308 redirect to https"
ok "http redirects to https"

echo "== mailpit"
c=$(code "mail.$DOMAIN" /);               [ "$c" = 401 ] || fail "mailpit UI without auth -> $c, expected 401"
c=$(code "mail.$DOMAIN" /api/v1/messages); [ "$c" = 401 ] || fail "mailpit API without auth -> $c, expected 401"
c=$(code "mail.$DOMAIN" / -u "$(val MAILPIT_UI_AUTH)"); [ "$c" = 200 ] || fail "mailpit UI with auth -> $c, expected 200"
ok "mailpit UI and API locked behind basic auth"

echo "smoke: all checks passed"
```

Run: `chmod +x scripts/smoke.sh`

- [ ] **Step 3 : vérifier que le test échoue**

Run: `scripts/smoke.sh`
Expected: FAIL avec `missing .env …` (ni `.env` ni `compose.yml` n'existent encore).

- [ ] **Step 4 : écrire `caddy/Caddyfile`**

```caddyfile
{
	# Sign every site with Caddy's own local CA (no public domain locally nor on the campus VM)
	local_certs
	# Running in a container: never try to touch a system trust store
	skip_install_trust
}

rallly.{$DOMAIN} {
	reverse_proxy rallly:3000
}

auth.{$DOMAIN} {
	reverse_proxy authentik-server:9000
}

mail.{$DOMAIN} {
	reverse_proxy mailpit:8025
}
```

- [ ] **Step 5 : écrire `compose.yml` (version Task 1)**

```yaml
name: rallly-lab

services:
  caddy:
    image: caddy:${CADDY_TAG:-2.11.7-alpine}
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      DOMAIN: ${DOMAIN:-localhost}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      edge:
        # Containers resolve the public hostnames to caddy, so server-side calls
        # (Rallly -> Authentik OIDC discovery) use the same URLs as the browser.
        aliases:
          - rallly.${DOMAIN:-localhost}
          - auth.${DOMAIN:-localhost}
          - mail.${DOMAIN:-localhost}
    healthcheck:
      test: ["CMD-SHELL", "test -f /data/caddy/pki/authorities/local/root.crt"]
      interval: 5s
      timeout: 3s
      retries: 12

  # One-shot: Caddy keeps its PKI root-only (0600) next to the CA private key.
  # Copy only the public root cert into its own volume, readable by app users.
  caddy-ca:
    image: caddy:${CADDY_TAG:-2.11.7-alpine}
    restart: "no"
    network_mode: none
    command: ["install", "-m", "0644", "/data/caddy/pki/authorities/local/root.crt", "/caddy-ca/root.crt"]
    volumes:
      - caddy-data:/data:ro
      - caddy-ca:/caddy-ca
    depends_on:
      caddy:
        condition: service_healthy

  mailpit:
    image: axllent/mailpit:${MAILPIT_TAG:-v1.31.4}
    restart: unless-stopped
    environment:
      # Anyone reading Mailpit can use any Rallly magic link: always lock the UI/API
      MP_UI_AUTH: ${MAILPIT_UI_AUTH:?set MAILPIT_UI_AUTH in .env (user:password)}
    networks:
      - edge

networks:
  edge:

volumes:
  caddy-data:
  caddy-config:
  caddy-ca:
```

- [ ] **Step 6 : écrire `.env.example` (version Task 1)**

```dotenv
# Copy to .env, then generate the secrets (commands in README.md, "Démarrage").
# Variables with no value are required: `docker compose up` refuses to start without them.

# ── Hostnames ───────────────────────────────────────────────────
# Services are served at rallly.$DOMAIN, auth.$DOMAIN and mail.$DOMAIN
DOMAIN=localhost

# ── Image tags (bump here) ──────────────────────────────────────
CADDY_TAG=2.11.7-alpine
MAILPIT_TAG=v1.31.4

# ── Mailpit (lab SMTP) ──────────────────────────────────────────
# Basic auth for the web UI and API, format user:password
# admin:$(openssl rand -hex 12)
MAILPIT_UI_AUTH=
```

- [ ] **Step 7 : créer un `.env` local et lancer le smoke**

```bash
cp .env.example .env
sed -i "s|^MAILPIT_UI_AUTH=.*|MAILPIT_UI_AUTH=admin:$(openssl rand -hex 12)|" .env
scripts/smoke.sh
```

Expected : toutes les sections Task 1 en `ok`, puis `smoke: all checks passed`.

En cas d'échec :
- `mailpit` unhealthy : `MP_UI_AUTH` protège peut-être aussi `/readyz`, l'endpoint utilisé par le healthcheck intégré. Lancer `docker compose exec mailpit /mailpit readyz; echo $?`. Si le code de sortie est non nul, ajouter au service `mailpit` :
  ```yaml
      healthcheck:
        test: ["CMD-SHELL", "wget -q -O /dev/null http://$$MP_UI_AUTH@localhost:8025/readyz"]
        interval: 15s
        start_period: 10s
  ``` Consigner le résultat dans la section Pièges du README (Task 4).
- `80`/`443` déjà pris sur l'hôte : arrêter le service qui les occupe (IIS, autre stack). Ce n'est pas un bug du compose.

- [ ] **Step 8 : Commit (seulement si César l'autorise)**

```bash
git add .gitignore .env.example compose.yml caddy/Caddyfile scripts/smoke.sh
git commit -m "feat(compose): add caddy proxy with local CA and locked mailpit"
```

---

### Task 2 : Rallly et sa base

**Files:**
- Modify: `compose.yml` (ajout de 2 services, d'un réseau et d'un volume), `.env.example` (ajout d'une section), `scripts/smoke.sh` (insertion avant `echo "smoke: all checks passed"`)

**Interfaces:**
- Consumes : réseau `edge`, volume `caddy-ca` (`/caddy-ca/root.crt`), service `caddy-ca` (`service_completed_successfully`), SMTP `mailpit:1025`, et dans le smoke les fonctions `code`, `hairpin`, `ok`, `fail` et la variable `DOMAIN`.
- Produces :
  - le service `rallly` (port interne 3000, `/api/status` → 200), le service `rallly-db`, le réseau `rallly-db` et le volume `rallly-db-data` ;
  - la preuve que `hairpin` fonctionne, réutilisée en Task 3 pour `auth.${DOMAIN}`.

- [ ] **Step 1 : ajouter les tests Rallly au smoke**

Insérer juste avant `echo "smoke: all checks passed"` :

```bash
echo "== rallly"
c=$(code "rallly.$DOMAIN" /api/status); [ "$c" = 200 ] || fail "rallly /api/status -> $c, expected 200"
ok "rallly answers through caddy"
hairpin "https://mail.$DOMAIN/readyz" || fail "rallly container cannot reach https://mail.$DOMAIN (alias or CA trust)"
ok "rallly container trusts caddy CA and resolves public hostnames"

echo "== isolation"
docker compose exec -T caddy getent hosts mailpit >/dev/null || fail "isolation probe broken: caddy cannot resolve mailpit"
docker compose exec -T caddy getent hosts rallly-db >/dev/null && fail "rallly-db is reachable from the edge network"
ok "rallly-db only on its internal network"
```

- [ ] **Step 2 : vérifier que le test échoue**

Run: `scripts/smoke.sh`
Expected : `FAIL  rallly /api/status -> 502, expected 200` (Caddy répond, mais `rallly` n'existe pas encore).

- [ ] **Step 3 : ajouter Rallly et sa base dans `compose.yml`**

Sous `services:`, après `mailpit` :

```yaml
  rallly:
    image: ${RALLLY_IMAGE:-lukevella/rallly:4.15.4}
    restart: unless-stopped
    environment:
      NEXT_PUBLIC_BASE_URL: https://rallly.${DOMAIN:-localhost}
      SECRET_PASSWORD: ${RALLLY_SECRET_PASSWORD:?set RALLLY_SECRET_PASSWORD in .env (min 32 chars)}
      DATABASE_URL: postgres://rallly:${RALLLY_DB_PASSWORD:?set RALLLY_DB_PASSWORD in .env}@rallly-db:5432/rallly
      SUPPORT_EMAIL: ${SUPPORT_EMAIL:-support@lab.test}
      NOREPLY_EMAIL: noreply@lab.test
      INITIAL_ADMIN_EMAIL: ${RALLLY_ADMIN_EMAIL:-admin@lab.test}
      SMTP_HOST: mailpit
      SMTP_PORT: "1025"
      SMTP_SECURE: "false"
      # Trust Caddy's local CA for server-side calls (OIDC discovery in J2). Read once at startup.
      NODE_EXTRA_CA_CERTS: /caddy-ca/root.crt
    volumes:
      - caddy-ca:/caddy-ca:ro
    networks:
      - edge
      - rallly-db
    depends_on:
      rallly-db:
        condition: service_healthy
      caddy-ca:
        condition: service_completed_successfully

  rallly-db:
    image: postgres:18-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: rallly
      POSTGRES_PASSWORD: ${RALLLY_DB_PASSWORD:?set RALLLY_DB_PASSWORD in .env}
      POSTGRES_DB: rallly
    volumes:
      # postgres >= 18 expects the volume at /var/lib/postgresql (not .../data)
      - rallly-db-data:/var/lib/postgresql
    networks:
      - rallly-db
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U rallly -d rallly"]
      interval: 5s
      timeout: 5s
      retries: 10
```

Sous `networks:`, après `edge:` :

```yaml
  rallly-db:
    internal: true
```

Sous `volumes:`, après `caddy-ca:` :

```yaml
  rallly-db-data:
```

- [ ] **Step 4 : compléter `.env.example`**

Ajouter, entre la section « Image tags » et la section « Mailpit » :

```dotenv
# ── Rallly ──────────────────────────────────────────────────────
# Override to run the custom image built by CI (J4)
RALLLY_IMAGE=lukevella/rallly:4.15.4
# Session encryption key, min 32 chars: openssl rand -base64 32
RALLLY_SECRET_PASSWORD=
# Hex only, so it needs no escaping inside DATABASE_URL: openssl rand -hex 24
RALLLY_DB_PASSWORD=
SUPPORT_EMAIL=support@lab.test
# Logs in by magic link, read in Mailpit
RALLLY_ADMIN_EMAIL=admin@lab.test
```

- [ ] **Step 5 : remplir les nouveaux secrets dans `.env` et relancer le smoke**

```bash
cat >>.env <<EOF
RALLLY_SECRET_PASSWORD=$(openssl rand -base64 32)
RALLLY_DB_PASSWORD=$(openssl rand -hex 24)
EOF
scripts/smoke.sh
```

Expected : toutes les sections jusqu'à `isolation` en `ok`, puis `smoke: all checks passed`. Le premier démarrage de Rallly lance `prisma migrate deploy` : compter environ 30 s de plus.

En cas d'échec de `hairpin` :
- avec `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` (le TLS échoue) : vérifier que `docker compose exec rallly cat /caddy-ca/root.crt` affiche un certificat ;
- avec `ENOTFOUND` : vérifier les alias de `caddy` avec `docker compose config | grep -A4 aliases`.

- [ ] **Step 6 : Commit (seulement si César l'autorise)**

```bash
git add compose.yml .env.example scripts/smoke.sh
git commit -m "feat(compose): add rallly and its isolated postgres"
```

---

### Task 3 : Authentik (server, worker, base) et envoi de mail

**Files:**
- Modify: `compose.yml` (ajout d'une ancre `x-authentik-env`, de 3 services, d'un réseau et de 3 volumes), `.env.example` (ajout d'une section), `scripts/smoke.sh` (insertion avant `echo "smoke: all checks passed"`)

**Interfaces:**
- Consumes : réseau `edge`, SMTP `mailpit:1025`, `hairpin` et `code` dans le smoke, la variable `MAILPIT_UI_AUTH`.
- Produces :
  - `https://auth.${DOMAIN}` (le health `/-/health/live/` répond 2xx) ;
  - le compte `akadmin` créé avec `AUTHENTIK_BOOTSTRAP_EMAIL` et `AUTHENTIK_BOOTSTRAP_PASSWORD` ;
  - l'envoi de mail d'Authentik vers Mailpit, prérequis des invitations de J2 ;
  - les services `authentik-server`, `authentik-worker` et `authentik-db`, les volumes `authentik-data`, `authentik-media` et `authentik-db-data`, le réseau `authentik-db`.

- [ ] **Step 1 : ajouter les tests Authentik au smoke**

Insérer juste avant `echo "smoke: all checks passed"` :

```bash
echo "== authentik"
c=$(code "auth.$DOMAIN" /-/health/live/); [[ "$c" == 2?? ]] || fail "authentik health -> $c, expected 2xx"
ok "authentik answers through caddy"
hairpin "https://auth.$DOMAIN/-/health/live/" || fail "rallly container cannot reach https://auth.$DOMAIN (OIDC in J2 will fail)"
ok "rallly container reaches authentik over https (OIDC-ready)"
docker compose exec -T caddy getent hosts authentik-db >/dev/null && fail "authentik-db is reachable from the edge network"
ok "authentik-db only on its internal network"

echo "== mail from authentik"
docker compose exec -T authentik-worker ak test_email smoke@lab.test >/dev/null 2>&1 \
  || fail "ak test_email failed (check AUTHENTIK_EMAIL__* and mailpit)"
got=
for _ in 1 2 3 4 5; do
  curl -s --max-time 10 --cacert "$CA" --resolve "mail.$DOMAIN:443:$IP" -u "$(val MAILPIT_UI_AUTH)" \
    "https://mail.$DOMAIN/api/v1/search?query=to:smoke@lab.test" | grep -q '"messages_count":[1-9]' && { got=1; break; }
  sleep 2
done
[ -n "$got" ] || fail "no mail to smoke@lab.test in mailpit"
ok "authentik mail captured by mailpit"
```

- [ ] **Step 2 : vérifier que le test échoue**

Run: `scripts/smoke.sh`
Expected : `FAIL  authentik health -> 502, expected 2xx`.

- [ ] **Step 3 : ajouter Authentik dans `compose.yml`**

En tête de fichier, juste après `name: rallly-lab` :

```yaml
x-authentik-env: &authentik-env
  AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET_KEY:?set AUTHENTIK_SECRET_KEY in .env}
  AUTHENTIK_POSTGRESQL__HOST: authentik-db
  AUTHENTIK_POSTGRESQL__NAME: authentik
  AUTHENTIK_POSTGRESQL__USER: authentik
  AUTHENTIK_POSTGRESQL__PASSWORD: ${AUTHENTIK_DB_PASSWORD:?set AUTHENTIK_DB_PASSWORD in .env}
  # Read on first startup only: creates akadmin without the initial-setup flow
  AUTHENTIK_BOOTSTRAP_EMAIL: ${AUTHENTIK_BOOTSTRAP_EMAIL:-akadmin@lab.test}
  AUTHENTIK_BOOTSTRAP_PASSWORD: ${AUTHENTIK_BOOTSTRAP_PASSWORD:?set AUTHENTIK_BOOTSTRAP_PASSWORD in .env}
  AUTHENTIK_EMAIL__HOST: mailpit
  AUTHENTIK_EMAIL__PORT: "1025"
  AUTHENTIK_EMAIL__USE_TLS: "false"
  AUTHENTIK_EMAIL__USE_SSL: "false"
  AUTHENTIK_EMAIL__FROM: authentik@lab.test
```

Sous `services:`, après `rallly-db` :

```yaml
  # Differences from the upstream authentik compose: no docker.sock and no root on the worker
  # (only needed for outposts), no published 9000/9443, named volumes instead of bind mounts.
  authentik-server:
    image: ghcr.io/goauthentik/server:${AUTHENTIK_TAG:-2026.8.3}
    command: server
    restart: unless-stopped
    shm_size: 512mb
    environment: *authentik-env
    volumes: &authentik-volumes
      - authentik-data:/data
      # The image symlinks /data/media -> /media; give /media its own volume so uploads persist
      - authentik-media:/media
    networks:
      - edge
      - authentik-db
    depends_on:
      authentik-db:
        condition: service_healthy

  authentik-worker:
    image: ghcr.io/goauthentik/server:${AUTHENTIK_TAG:-2026.8.3}
    command: worker
    restart: unless-stopped
    shm_size: 512mb
    environment: *authentik-env
    volumes: *authentik-volumes
    networks:
      - edge
      - authentik-db
    depends_on:
      authentik-db:
        condition: service_healthy

  authentik-db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: authentik
      POSTGRES_PASSWORD: ${AUTHENTIK_DB_PASSWORD:?set AUTHENTIK_DB_PASSWORD in .env}
      POSTGRES_DB: authentik
    volumes:
      - authentik-db-data:/var/lib/postgresql/data
    networks:
      - authentik-db
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U authentik -d authentik"]
      interval: 5s
      timeout: 5s
      retries: 10
```

Sous `networks:`, après `rallly-db:` :

```yaml
  authentik-db:
    internal: true
```

Sous `volumes:`, après `rallly-db-data:` :

```yaml
  authentik-data:
  authentik-media:
  authentik-db-data:
```

- [ ] **Step 4 : compléter `.env.example`**

Ajouter, entre la section « Rallly » et la section « Mailpit » :

```dotenv
# ── Authentik ───────────────────────────────────────────────────
AUTHENTIK_TAG=2026.8.3
# openssl rand -base64 60 | tr -d '\n'
AUTHENTIK_SECRET_KEY=
# openssl rand -hex 24
AUTHENTIK_DB_PASSWORD=
# Admin account "akadmin", created on FIRST startup only (changing these later has no effect)
AUTHENTIK_BOOTSTRAP_EMAIL=akadmin@lab.test
# openssl rand -base64 18
AUTHENTIK_BOOTSTRAP_PASSWORD=
```

- [ ] **Step 5 : remplir les nouveaux secrets dans `.env` et relancer le smoke**

```bash
cat >>.env <<EOF
AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')
AUTHENTIK_DB_PASSWORD=$(openssl rand -hex 24)
AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 18)
EOF
scripts/smoke.sh
```

Expected : toutes les sections en `ok`, puis `smoke: all checks passed`. Le premier `up --wait` prend environ 2 min.

En cas d'échec :
- `ak test_email` : lire `docker compose exec authentik-worker ak test_email smoke@lab.test` sans redirection, et vérifier l'option ou l'argument qu'il attend dans cette version avec `ak test_email --help`.
- Healthcheck du worker en échec : comparer avec `docker compose logs authentik-worker`. Il ne doit pas tenter d'accéder à `/var/run/docker.sock` : un warning de l'intégration outpost est attendu et sans effet.

- [ ] **Step 6 : Commit (seulement si César l'autorise)**

```bash
git add compose.yml .env.example scripts/smoke.sh
git commit -m "feat(compose): add authentik behind caddy with lab smtp"
```

---

### Task 4 : README, persistance, variante de DOMAIN et parcours navigateur

**Files:**
- Modify: `README.md` (remplacé entièrement)

**Interfaces:**
- Consumes : la stack complète des Tasks 1 à 3 et `scripts/smoke.sh`.
- Produces : un README qui suffit à démarrer depuis un clone propre ; les pièges consignés, servis à J2 et J3.

- [ ] **Step 1 : écrire `README.md`**

````markdown
# projet-infra

Infra du projet « Dev avec Docker » (M2 FullStack Ynov, 2026-2027) : Rallly derrière Authentik (OIDC), un reverse proxy unique, en local et sur VM Énov.
Le code des features Rallly vit dans le fork [`les-salopards/rallly`](https://github.com/les-salopards/rallly) ; ce dépôt contient tout le reste.

## Démarrage

Prérequis : Docker avec Compose v2, `openssl`, ports 80 et 443 libres.

```bash
cp .env.example .env
sed -i \
  -e "s|^RALLLY_SECRET_PASSWORD=.*|RALLLY_SECRET_PASSWORD=$(openssl rand -base64 32)|" \
  -e "s|^RALLLY_DB_PASSWORD=.*|RALLLY_DB_PASSWORD=$(openssl rand -hex 24)|" \
  -e "s|^AUTHENTIK_SECRET_KEY=.*|AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')|" \
  -e "s|^AUTHENTIK_DB_PASSWORD=.*|AUTHENTIK_DB_PASSWORD=$(openssl rand -hex 24)|" \
  -e "s|^AUTHENTIK_BOOTSTRAP_PASSWORD=.*|AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 18)|" \
  -e "s|^MAILPIT_UI_AUTH=.*|MAILPIT_UI_AUTH=admin:$(openssl rand -hex 12)|" \
  .env
docker compose up -d --wait --wait-timeout 300   # ~2 min au premier démarrage
scripts/smoke.sh                                 # vérifie toute la stack
```

Un `.env` incomplet fait échouer `docker compose up` avec le nom de la variable manquante.

## Accès

| Service | URL | Compte |
|---|---|---|
| Rallly | https://rallly.localhost | `admin@lab.test`, par magic link lu dans Mailpit |
| Authentik | https://auth.localhost | `akadmin` / `AUTHENTIK_BOOTSTRAP_PASSWORD` du `.env` |
| Mailpit (SMTP de lab) | https://mail.localhost | `MAILPIT_UI_AUTH` du `.env` (`user:password`) |

Tous les mails (Rallly, Authentik) sont capturés par Mailpit ; rien ne sort vers Internet.

### Certificat HTTPS

Caddy signe les sites avec sa propre autorité (CA). Pour supprimer l'avertissement du navigateur :

```bash
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```

- **Windows (Chrome, Edge)** : double-cliquer sur `caddy-root.crt` → Installer le certificat → Ordinateur local → « Autorités de certification racines de confiance ». Depuis WSL, le fichier est sous `\\wsl$\<distro>\<chemin du dépôt>`.
- **Firefox** : Paramètres → Vie privée et sécurité → Certificats → Afficher les certificats → Autorités → Importer.

La CA vit dans le volume `caddy-data`. Si ce volume est supprimé (`docker compose down -v`), une nouvelle CA est générée : il faut alors réimporter le certificat.

## Architecture

```
            hôte : seuls 80/443 publiés
                     │
                ┌────▼────┐   alias réseau : rallly.$DOMAIN,
                │  caddy  │   auth.$DOMAIN, mail.$DOMAIN
                └─┬──┬──┬─┘
     réseau edge  │  │  │
        ┌─────────┘  │  └──────────┐
   ┌────▼───┐  ┌─────▼──────────┐ ┌▼───────┐
   │ rallly │  │authentik-server│ │mailpit │◄─ SMTP 1025 (rallly, worker)
   └────┬───┘  │authentik-worker│ └────────┘
        │      └─────┬──────────┘
 rallly-db (internal)│ authentik-db (internal)
   ┌────▼─────┐ ┌────▼───────┐
   │ rallly-db│ │authentik-db│   aucun port publié
   └──────────┘ └────────────┘
```

- **Un seul point d'entrée** : Caddy (80 redirige vers 443). Aucune base n'est publiée ; chacune est sur un réseau `internal` sans route sortante.
- **Appels serveur → serveur** : les conteneurs résolvent `auth.$DOMAIN` vers Caddy grâce aux alias réseau. Rallly fait confiance à la CA de Caddy (`NODE_EXTRA_CA_CERTS`). Le service one-shot `caddy-ca` copie uniquement le certificat public : la clé de la CA reste dans `caddy-data`, illisible pour Rallly.
- Spec détaillée : [`docs/specs/2026-10-06-j1-compose-local.md`](docs/specs/2026-10-06-j1-compose-local.md).

## Écarts avec les composes upstream

| Upstream | Ici | Pourquoi |
|---|---|---|
| rallly-selfhosted : Traefik + Let's Encrypt | Caddy + CA interne | Pas de domaine public, ni en local ni sur la VM campus |
| rallly-selfhosted : Garage (S3) | absent | Ne sert qu'aux avatars et au branding, dont aucune de nos features n'a besoin |
| Authentik : worker en root avec `docker.sock` | worker non-root, sans socket | Le socket ne sert qu'aux outposts ; monter `docker.sock` revient à donner root sur l'hôte |
| Authentik : ports 9000/9443 publiés | non publiés | Point d'entrée unique |
| Authentik : bind mounts `./data`, `./certs` | volumes nommés `/data` et `/media` | Pas de problème de permissions sous WSL ; `/media` séparé car l'image contient le symlink `/data/media → /media` |

## Pièges rencontrés

- **Adresses `@localhost` refusées par Rallly** : son formulaire de login exige un TLD. Toutes les adresses de lab sont donc en `@lab.test`.
- **CA de Caddy illisible par Rallly** : Caddy crée sa PKI en `0600` root. D'où le service `caddy-ca`, qui copie uniquement `root.crt`.
- **Variables bootstrap d'Authentik** : lues au premier démarrage seulement. Pour changer le mot de passe d'`akadmin`, passer par l'UI, ou `docker compose down -v` (efface toutes les données).
- **`*.localhost` injoignable depuis Windows** : vérifier que WSL transmet localhost (`localhostForwarding` n'est pas à `false` dans `%UserProfile%\.wslconfig`).
````

- [ ] **Step 2 : vérifier la persistance après `down` / `up` (Review Focus 3)**

```bash
before=$(docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt | sha256sum)
docker compose down
docker compose up -d --wait --wait-timeout 300
after=$(docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt | sha256sum)
[ "$before" = "$after" ] && echo "CA stable" || echo "CA CHANGED"
scripts/smoke.sh
```

Expected : `CA stable`, puis `smoke: all checks passed`.

- [ ] **Step 3 : vérifier une autre valeur de `DOMAIN` (Review Focus 4)**

```bash
sed -i 's/^DOMAIN=.*/DOMAIN=lab.localhost/' .env
scripts/smoke.sh          # recrée caddy (alias) et rallly (NEXT_PUBLIC_BASE_URL)
c=$(docker compose exec -T rallly printenv NEXT_PUBLIC_BASE_URL); echo "$c"
sed -i 's/^DOMAIN=.*/DOMAIN=localhost/' .env
scripts/smoke.sh
```

Expected : les deux smokes passent, et la commande affiche `https://rallly.lab.localhost`.

- [ ] **Step 4 : rejouer le démarrage depuis un clone propre**

```bash
docker compose down -v
tmp=$(mktemp -d)
if [ -z "$(git status --porcelain)" ]; then
  git clone -q . "$tmp/projet-infra"   # everything committed: a real clean clone
else
  cp -r . "$tmp/projet-infra" && rm -f "$tmp/projet-infra/.env"   # uncommitted work: closest equivalent
fi
cd "$tmp/projet-infra"
# run the "Démarrage" block of README.md verbatim, then:
scripts/smoke.sh
docker compose down -v && cd - && rm -rf "$tmp"
```

Si des fichiers ne sont pas commités, `git clone` ne les contiendrait pas : le bloc copie alors le dossier en retirant le `.env`.
Expected : le bloc « Démarrage » du README, copié tel quel, aboutit à `smoke: all checks passed`.

Le nom de projet Compose est fixé (`name: rallly-lab`) : le clone temporaire partage donc conteneurs et volumes avec le dépôt principal. D'où le `down -v` avant et après.

- [ ] **Step 5 : relancer la stack principale et faire le parcours navigateur avec `/qa`**

```bash
cd /home/cesar/projects/scolaire/M2-docker/projet/projet-infra && docker compose up -d --wait --wait-timeout 300
```

Avec `/qa` (navigateur réel, sans importer la CA : accepter l'avertissement de certificat) :
1. https://rallly.localhost → login avec `admin@lab.test` → le mail arrive dans https://mail.localhost (identifiants `MAILPIT_UI_AUTH`) → le lien ou le code connecte Rallly, et l'utilisateur est admin (accès au Control Panel).
2. https://auth.localhost → login `akadmin` avec `AUTHENTIK_BOOTSTRAP_PASSWORD` → l'interface d'administration s'ouvre.

Expected : les deux parcours aboutissent. Toute surprise (redirection, cookie, avertissement bloquant) est ajoutée à « Pièges rencontrés » dans le README.

- [ ] **Step 6 : Commit (seulement si César l'autorise)**

```bash
git add README.md
git commit -m "docs: document local stack startup, access and pitfalls"
```
