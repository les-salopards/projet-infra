# projet-infra

Infra du projet M2 « Dev avec Docker » : reverse proxy, Authentik (OIDC) et Rallly.

Le code des features Rallly vit dans le fork : https://github.com/les-salopards/rallly

## Démarrage

```sh
cp .env.example .env   # remplir chaque valeur vide : openssl rand -base64 36 | tr -d '\n/+='
docker compose up -d --wait   # ~2 min au premier lancement
```

| URL | Service |
| --- | --- |
| https://rallly.localhost | Rallly (connexion uniquement via Authentik) |
| https://auth.localhost | Authentik (admin : `akadmin` / `AUTHENTIK_BOOTSTRAP_PASSWORD`) |
| https://mail.localhost | Mailpit (SMTP de lab : e-mails envoyés par Rallly et Authentik) |

Les certificats viennent de la CA interne de Caddy : le navigateur affiche un avertissement.
Pour l'éviter, importer la CA dans le magasin de certificats du poste :
`docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt caddy-root.crt`.

Comptes de démo (mot de passe = `DEMO_PASSWORD` du `.env`) :

| Compte | Groupe | Rallly |
| --- | --- | --- |
| `alice` | `rallly-users` | autorisé |
| `bob` | `rallly-admins` (admin Authentik) | autorisé |
| `charlie` | aucun | refusé par Authentik |

Configuration Authentik (SSO, policies, invitation) : [docs/authentik.md](docs/authentik.md).

## Architecture

```
navigateur ──443──> Caddy ─┬─> authentik-server ─┐   authentik-worker (blueprints)
                           │                     └─> authentik-db      [authentik-internal]
                           ├─> rallly ───────────────> rallly-db       [rallly-internal]
                           └─> mailpit
          réseau edge : caddy, authentik-*, rallly, mailpit
```

- Seul Caddy publie des ports (80, 443). Les bases sont sur des réseaux `internal`, sans port publié.
- Rallly joint Authentik par son URL publique `https://auth.<DOMAIN>` : Caddy porte cet alias sur le réseau `edge`,
  et le service ponctuel `caddy-ca` donne à Rallly le seul certificat racine de Caddy (`NODE_EXTRA_CA_CERTS`).
- Secrets : uniquement dans `.env` (gitignoré), jamais dans les images ni dans le dépôt.
