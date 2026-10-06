# Sécurité : durcissement et scan

Principe : chaque conteneur tourne **sans root**, **sans capacité Linux** (sauf exception justifiée), **sans gain de privilèges**,
et seul Caddy est joignable depuis l'extérieur (ports 80/443). Les choix ci-dessous ont été **testés un par un** (6 oct. 2026).

## Durcissement par service
| Service | Utilisateur | Capacités | Système de fichiers | Testé |
| --- | --- | --- | --- | --- |
| Caddy | `1000:1000` | `NET_BIND_SERVICE` uniquement | `read_only` + volumes `/data`, `/config` | uid 1000, HTTP 80 et HTTPS 443 servis |
| Postgres (×2) | `postgres` (uid 70) | aucune | `read_only` + tmpfs `/var/run/postgresql`, `/tmp` + volume données | initialisation + `pg_isready` OK |
| Mailpit | `1000:1000` | aucune | `read_only`, base dans tmpfs | `/readyz` OK |
| Authentik server/worker | `1000` (image) | aucune | volumes `media`, `certs`, `custom-templates` | à valider dans la stack complète |
| Rallly | `nextjs` (image, `USER` du Dockerfile) | aucune | à valider (`.next/cache` doit être inscriptible) | à valider dans la stack complète |

Communs à tous les services (bloc à reprendre dans `compose.yml`) :
```yaml
x-hardening: &hardening
  security_opt: ["no-new-privileges:true"]
  cap_drop: ["ALL"]
  restart: unless-stopped
  pids_limit: 256
  logging:
    driver: json-file
    options: { max-size: "10m", max-file: "3" }

services:
  caddy:
    <<: *hardening
    image: caddy:2.10-alpine
    user: "1000:1000"
    cap_add: ["NET_BIND_SERVICE"]
    read_only: true
    ports: ["80:80", "443:443"]       # les SEULS ports publiés de la stack
    volumes: [caddy-data:/data, caddy-config:/config, ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro]
    tmpfs: [/tmp]
    networks: [edge]

  rallly-db:
    <<: *hardening
    image: postgres:18-alpine
    user: postgres
    read_only: true
    tmpfs: ["/var/run/postgresql:uid=70,gid=70", /tmp]
    volumes: [rallly-db:/var/lib/postgresql]
    networks: [rallly-internal]        # pas de "ports:" : jamais exposée
```

### Réseaux
| Réseau | `internal` | Membres | Rôle |
| --- | --- | --- | --- |
| `edge` | non | caddy, authentik-server, rallly, mailpit | Caddy → applications |
| `authentik-internal` | **oui** | authentik-server, authentik-worker, authentik-db | BDD Authentik isolée, sans accès Internet |
| `rallly-internal` | **oui** | rallly, rallly-db | BDD Rallly isolée, sans accès Internet |

Piège : Rallly appelle la discovery OIDC d'Authentik **par son URL publique** (`https://auth.<DOMAIN>`).
Dans le conteneur, ce nom doit résoudre vers Caddy (alias réseau sur le service caddy) et Rallly doit faire
confiance à la CA interne de Caddy (`NODE_EXTRA_CA_CERTS=/caddy-ca/root.crt`, volume en lecture seule).

## Pièges rencontrés pendant les tests
- **Caddy + `cap_drop: ALL` → `exec /usr/bin/caddy: operation not permitted`.** Le binaire de l'image porte la file capability
  `cap_net_bind_service=+ep`. Le noyau refuse de l'exécuter si cette capacité manque au bounding set.
  Solution : `cap_add: [NET_BIND_SERVICE]`, la seule capacité de toute la stack.
- **Caddy `failed to install root certificate`** : Caddy tente d'installer sa CA dans le trust store du conteneur (impossible en non-root).
  C'est sans effet ; on peut ajouter `skip_install_trust` dans les options globales du Caddyfile.
- **Postgres en non-root** : ça fonctionne directement avec un volume nommé, car Docker copie la propriété (uid 70) du dossier de l'image.
  Avec un *bind mount*, il faudrait un `chown 70:70` au préalable.

## Scan
`./scripts/scan.sh` fait tout dans des conteneurs, sans rien installer sur la machine :
- **Trivy** : CVE HIGH/CRITICAL corrigeables dans les images du Compose, puis erreurs de configuration du Compose et des Dockerfiles ;
- **hadolint** : bonnes pratiques Dockerfile ;
- **gitleaks** : secrets dans tout l'historique Git.

Rapports dans `reports/` (gitignoré). Le script renvoie un code d'erreur si une CVE critique corrigeable ou un secret est trouvé, ce qui permet de l'utiliser en CI.

### Résultats commentés — premier scan, 6 oct. 2026 (images upstream, avant build de notre image Rallly)
CVE **corrigeables** de sévérité HIGH ou CRITICAL (Trivy 0.75.0) :

| Image | CRITICAL | HIGH | Où | Verdict |
| --- | --- | --- | --- | --- |
| `caddy:2-alpine` | 0 | 0 | — | RAS |
| `axllent/mailpit` | 0 | 0 | — | RAS (et service de lab uniquement) |
| `postgres:18-alpine` | 1 | 21 | **toutes dans `/usr/local/bin/gosu`** (stdlib Go 1.24.6) | **Non exploitable chez nous.** L'entrypoint n'appelle `gosu` que s'il démarre en root. Avec `user: postgres`, il n'est jamais exécuté. La CVE critique (CVE-2025-68121) touche la reprise de session TLS côté client, et `gosu` ne fait pas de réseau. |
| `lukevella/rallly` | 4 | 15 | `perl-base` (3 C), `fast-xml-parser` (1 C), dépendances npm | **Corrigé dans notre image.** Même un `node:24-slim` fraîchement tiré embarque `perl-base 5.36.0-7+deb12u3` (3 critiques). Notre Dockerfile ajoute `apt-get upgrade` dans l'étape `runner` (branche du fork `hardening/runner-image`). Vérifié : 3 CRITICAL → 0 sur l'image de base. `fast-xml-parser` (XSS via DOCTYPE) vient du SDK AWS S3 : il n'est utilisé que si S3 est configuré, ce qui n'est pas notre cas. `mysql2` est présent mais inutilisé (on est sur Postgres). |
| `ghcr.io/goauthentik/server:2026.8.3` | 2 | 21 | `PyJWT` 2.13.0, `anyio` 4.14.1, `openssl`, `urllib3` | **Accepté et surveillé.** C'est le dernier patch publié (`2026.8` = `2026.8.3`, même digest), donc pas de correctif disponible côté image. PyJWT (CVE-2026-102268) n'est exploitable que si l'application mélange HMAC et clés asymétriques. Mitigation : provider OIDC signé avec une **clé RS256** (pas de HS256). anyio (CVE-2026-63374) concerne les noms de domaine internationalisés en TLS sortant, et Authentik ne contacte ici aucun hôte externe. À mettre à jour dès la `2026.8.4`. |

Pour relancer : `./scripts/scan.sh` (toutes les images du Compose) ou `./scripts/scan.sh <image>`.

## Limites assumées
- TLS par la CA interne de Caddy : le chiffrement est réel, mais le certificat n'est pas reconnu par les navigateurs sans import de la CA.
- Les images tierces (Authentik, Postgres, Caddy) sont épinglées par tag, pas par digest : la reproductibilité est meilleure qu'avec `latest`, mais pas parfaite.
- Les CVE sans correctif publié (`--ignore-unfixed`) ne sont pas listées : on ne peut rien y faire à part changer d'image.
