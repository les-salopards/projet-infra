# Sécurité : durcissement et scan

Principe : chaque conteneur tourne **sans root**, **sans capacité Linux** (sauf exception justifiée), **sans gain de privilèges**,
avec un **système de fichiers en lecture seule**, et seul Caddy est joignable depuis l'extérieur (ports 80/443).
Chaque réglage a été testé service par service (6 oct. 2026), puis dans la stack complète (17 nov. 2026).

Ces règles sont **vérifiées automatiquement** par `scripts/check-compose.py` (lancé par `./scripts/scan.sh` et la CI) :
un service sans `cap_drop: ALL`, sans `read_only` ou avec un port publié en trop fait échouer le scan.

## Durcissement par service
Valeurs relevées dans les conteneurs en marche (`id`, `CapEff` et `NoNewPrivs` de `/proc/1/status`, `ReadonlyRootfs`) :

| Service | Utilisateur | Capacités effectives | Système de fichiers | Vérifié dans la stack complète |
| --- | --- | --- | --- | --- |
| Caddy | `1000:1000` | aucune (`NET_BIND_SERVICE` dans le bounding set, voir pièges) | `read_only` + volumes `/data`, `/config` + tmpfs `/tmp` | HTTP 80 / HTTPS 443 servis |
| caddy-ca (one-shot) | `root` | `DAC_OVERRIDE` uniquement | `read_only`, `network_mode: none` | copie `root.crt` puis `exited (0)` |
| Postgres (×2) | `postgres` (uid 70) | aucune | `read_only` + tmpfs `/var/run/postgresql`, `/tmp` + volume données | `pg_isready` OK |
| Mailpit | `1000:1000` | aucune | `read_only`, base dans tmpfs | `/readyz` OK, e-mails reçus |
| Authentik server/worker | `1000` (`authentik`, `USER` de l'image) | aucune | `read_only` + volume `/data` + tmpfs `/tmp` (64 Mo) | SSO, policies, blueprint *successful*, e-mail envoyé |
| Rallly | `100` (`nextjs`, `USER` de l'image) | aucune | `read_only` + tmpfs `/tmp`, `.next/cache`, `node_modules/.cache` | SSO OIDC, `/api/status` OK |

`no-new-privileges` est actif (`NoNewPrivs: 1`) dans les 8 conteneurs.

**Comment les chemins inscriptibles ont été trouvés** : stack lancée sans `read_only`, puis
`find / -xdev -newer /etc/hostname -type f` dans chaque conteneur pour lister ce que l'application écrit.
- Rallly écrit dans `/app/apps/web/.next/cache` (cache `fetch` de Next.js) et `/app/node_modules/.cache`
  (cache `jiti` de `prisma migrate deploy`, lancé à chaque démarrage). Rien d'autre.
- Authentik n'écrit que dans `/data` (volume) et `/dev/shm` (`shm_size`). `/tmp` en tmpfs par précaution.
- Les tmpfs sont en mode `1777` (valeur par défaut de Docker) et limités en taille : ils fonctionnent quel que soit
  l'uid de l'image (upstream ou fork) et un processus ne peut pas remplir la RAM de l'hôte.

**Test de non-régression** fait avec `read_only` activé : connexion SSO complète d'`alice` et `bob` jusqu'à une session
Rallly, refus de `charlie` par la policy (*Permission denied*), blueprint `projet-infra - Rallly` au statut *successful*,
`ak test_email` reçu dans Mailpit.

Bloc commun à tous les services (`x-hardening` dans [`compose.yml`](../compose.yml)) :
```yaml
x-hardening: &hardening
  security_opt: ["no-new-privileges:true"]
  cap_drop: ["ALL"]
  restart: unless-stopped
  pids_limit: 256
  logging:
    driver: json-file
    options: { max-size: "10m", max-file: "3" }
```

### Réseaux
| Réseau | `internal` | Membres | Rôle |
| --- | --- | --- | --- |
| `edge` | non | caddy, authentik-server, authentik-worker, rallly, mailpit | Caddy → applications ; SMTP vers Mailpit |
| `authentik-internal` | **oui** | authentik-server, authentik-worker, authentik-db | BDD Authentik isolée, sans accès Internet |
| `rallly-internal` | **oui** | rallly, rallly-db | BDD Rallly isolée, sans accès Internet |

Aucune base n'a de `ports:`. Seul Caddy publie 80 et 443 (vérifié par `check-compose.py` et par `deploy/deploy.sh` sur la VM).

Piège : Rallly appelle la discovery OIDC d'Authentik **par son URL publique** (`https://auth.<DOMAIN>`).
Dans le conteneur, ce nom doit résoudre vers Caddy (alias réseau sur le service caddy) et Rallly doit faire
confiance à la CA interne de Caddy (`NODE_EXTRA_CA_CERTS=/caddy-ca/root.crt`, volume en lecture seule).

## Pièges rencontrés pendant les tests
- **Caddy + `cap_drop: ALL` → `exec /usr/bin/caddy: operation not permitted`.** Le binaire de l'image porte la file capability
  `cap_net_bind_service=+ep`. Le noyau refuse de l'exécuter si cette capacité manque au bounding set.
  Solution : `cap_add: [NET_BIND_SERVICE]`, seule capacité d'un service permanent.
- **Caddy `failed to install root certificate`** : Caddy tente d'installer sa CA dans le trust store du conteneur (impossible en non-root).
  C'est sans effet ; `skip_install_trust` dans les options globales du Caddyfile supprime le message.
- **Postgres en non-root** : ça fonctionne directement avec un volume nommé, car Docker copie la propriété (uid 70) du dossier de l'image.
  Avec un *bind mount*, il faudrait un `chown 70:70` au préalable.
- **`trivy config` ne lit pas les fichiers Compose** (« Not scanned ») : il ne vérifiait rien. Remplacé par `check-compose.py`,
  qui contrôle le Compose **résolu** (`docker compose config`), ancres YAML et variables comprises.

## Scan
`./scripts/scan.sh` fait tout dans des conteneurs (seul `python3` est requis sur la machine) :
- **Trivy** : CVE HIGH/CRITICAL **corrigeables** dans chaque image du Compose ;
- **check-compose.py** : règles de durcissement ci-dessus sur le Compose résolu ;
- **hadolint** : bonnes pratiques des Dockerfiles du dépôt (l'image Rallly est construite et scannée dans le fork) ;
- **gitleaks** : secrets dans tout l'historique Git.

Rapports dans `reports/` (gitignoré). Le script renvoie un code d'erreur si une CVE critique corrigeable **non acceptée**,
une règle de durcissement violée ou un secret est trouvé.

**CI** : `.github/workflows/security-scan.yml` lance le même script à chaque push sur `main`, sur chaque PR et chaque lundi
(nouvelles CVE sur des images inchangées). Les rapports sont joints au run. Le fork peut l'appeler après le build de son image.

**Risques acceptés** : [`.trivyignore`](../.trivyignore) liste les CVE critiques jugées non exploitables, chacune avec une date
d'expiration. Passé cette date, Trivy les signale à nouveau et la CI repasse au rouge, ce qui oblige à réévaluer.

### Résultats commentés — 17 nov. 2026 (Trivy 0.75.0, images de `compose.yml`)
CVE **corrigeables** de sévérité HIGH ou CRITICAL :

| Image | CRITICAL | HIGH | Où | Verdict |
| --- | --- | --- | --- | --- |
| `axllent/mailpit:v1.33` | 0 | 0 | — | RAS (service de lab uniquement). |
| `caddy:2.11-alpine` | 0 | 1 | `golang.org/x/net/html` | **Non atteignable.** Déni de service sur le *parseur HTML* ; Caddy ne fait ici que du `reverse_proxy` (pas de `templates` ni de `markdown`), il ne parse jamais de HTML. |
| `postgres:18-alpine` | 1 | 25 | **toutes dans `/usr/local/bin/gosu`** (stdlib Go 1.24.6) | **Non exploitable chez nous (accepté).** L'entrypoint n'appelle `gosu` que s'il démarre en root ; avec `user: postgres`, il n'est jamais exécuté. La critique (CVE-2025-68121) touche la reprise de session TLS côté client, et `gosu` ne fait pas de réseau. |
| `lukevella/rallly:4.17` | 0 | 6 | `undici` 6.28.0, `brace-expansion` 5.0.9, **tous dans le CLI `npm` livré avec l'image** (`/usr/local/lib/node_modules/npm`) | **Hors du code applicatif.** Rallly n'importe pas ces copies ; `npm` ne sert qu'à `npx prisma migrate deploy` au démarrage, avec le Prisma déjà installé (aucun téléchargement). Piste pour l'image du fork : appeler `node_modules/.bin/prisma` directement et supprimer `npm` de l'étape `runner`. Les 3 CRITICAL `perl-base` du 6 oct. ont disparu de l'image upstream ; le fork garde son `apt-get upgrade` (branche `hardening/runner-image`) pour ne pas en dépendre. |
| `ghcr.io/goauthentik/server:2026.8.5` | 1 | 70 | `libbrotli1` (C), `libpq5` (34 H), `aiohttp`, `urllib3`, `pyasn1`… | **Montée de version faite : 5 CRITICAL → 1.** Passer de `2026.8.3` à `2026.8.5` corrige PyJWT (contournement d'authentification), `certifi` (CA emSign compromises) et `anyio`. Reste `libbrotli1` (écriture hors limites dans le décodeur Brotli) : pas de correctif dans la dernière image publiée, **accepté jusqu'au 31/12/2026** car Authentik n'est joignable que via Caddy depuis le VPN Énov. `libpq5` : client Postgres, ne parle qu'à `authentik-db` sur un réseau `internal`. |

Historique : au premier scan (6 oct., `2026.8.3` et Rallly upstream), il y avait 7 CRITICAL corrigeables ; il en reste 2, toutes deux justifiées dans `.trivyignore`.

Pour relancer : `./scripts/scan.sh` (toutes les images du Compose) ou `./scripts/scan.sh <image>`.

## Limites assumées
- TLS par la CA interne de Caddy : le chiffrement est réel, mais le certificat n'est pas reconnu par les navigateurs sans import de la CA.
- Les images tierces (Authentik, Postgres, Caddy) sont épinglées par tag, pas par digest : la reproductibilité est meilleure qu'avec `latest`, mais pas parfaite.
- Les CVE sans correctif publié (`--ignore-unfixed`) ne sont pas listées : on ne peut rien y faire à part changer d'image.
- `caddy-ca` tourne en root (avec `DAC_OVERRIDE` seulement) le temps de copier le certificat racine : sans réseau, en lecture seule, il s'arrête aussitôt.
- Les HIGH restants ne bloquent pas la CI (seuls les CRITICAL le font) : ils sont commentés ici, à chaque nouveau scan.
