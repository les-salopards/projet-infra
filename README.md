# projet-infra

Infra du projet « Dev avec Docker » (M2 FullStack Ynov, 2026-2027) : Rallly derrière Authentik (OIDC), un reverse proxy unique, en local et sur VM Énov.
Le code des features Rallly vit dans le fork [`les-salopards/rallly`](https://github.com/les-salopards/rallly) ; ce dépôt contient tout le reste.

## Démarrage

Prérequis : Docker avec Compose v2, `openssl`, ports 80 et 443 libres.

```bash
[ -f .env ] || cp .env.example .env   # never overwrite an existing .env
# Fills only empty secrets: safe to re-run, existing values are kept
sed -i \
  -e "s|^RALLLY_SECRET_PASSWORD=$|RALLLY_SECRET_PASSWORD=$(openssl rand -base64 32)|" \
  -e "s|^RALLLY_DB_PASSWORD=$|RALLLY_DB_PASSWORD=$(openssl rand -hex 24)|" \
  -e "s|^AUTHENTIK_SECRET_KEY=$|AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')|" \
  -e "s|^AUTHENTIK_DB_PASSWORD=$|AUTHENTIK_DB_PASSWORD=$(openssl rand -hex 24)|" \
  -e "s|^AUTHENTIK_BOOTSTRAP_PASSWORD=$|AUTHENTIK_BOOTSTRAP_PASSWORD=$(openssl rand -base64 18)|" \
  -e "s|^MAILPIT_UI_AUTH=$|MAILPIT_UI_AUTH=admin:$(openssl rand -hex 12)|" \
  .env
docker compose up -d --wait --wait-timeout 300   # ~2 min au premier démarrage
scripts/smoke.sh                                 # vérifie toute la stack
```

Un `.env` incomplet fait échouer `docker compose up` avec le nom de la variable manquante.

## Accès

| Service | URL | Compte |
|---|---|---|
| Rallly | https://rallly.localhost | `admin@lab.test`, par code de connexion lu dans Mailpit, puis https://rallly.localhost/admin-setup → « Make me an admin » |
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

- **Admin Rallly pas automatique** : `INITIAL_ADMIN_EMAIL` ne donne pas le rôle admin à la connexion. Il autorise seulement cette adresse à le réclamer sur `/admin-setup`.
- **Adresses `@localhost` refusées par Rallly** : son formulaire de login exige un TLD. Toutes les adresses de lab sont donc en `@lab.test`.
- **CA de Caddy illisible par Rallly** : Caddy crée sa PKI en `0600` root. D'où le service `caddy-ca`, qui copie uniquement `root.crt`.
- **Variables bootstrap d'Authentik** : lues au premier démarrage seulement. Pour changer le mot de passe d'`akadmin`, passer par l'UI, ou `docker compose down -v` (efface toutes les données).
- **`*.localhost` injoignable depuis Windows** : vérifier que WSL transmet localhost (`localhostForwarding` n'est pas à `false` dans `%UserProfile%\.wslconfig`).
- **Port 80 déjà pris** (`address already in use`) : souvent un Apache installé dans WSL. `sudo ss -ltnp | grep ':80 '` pour le trouver, `sudo systemctl disable --now apache2` pour le couper. Si Caddy a été créé pendant que le port était pris, il peut tourner sans aucun port publié : `docker compose up -d --force-recreate caddy`.
- **`ak test_email` en `ResultTimeout` juste après le premier démarrage** : le worker Authentik est healthy mais encore occupé par ses tâches d'initialisation. Le mail reste en file et arrive dans Mailpit une minute plus tard ; `scripts/smoke.sh` en tient compte.
- **`docker compose up --wait` et `caddy-ca`** : `--wait` échoue sur un service one-shot terminé dont personne ne dépend. `caddy-ca` doit donc toujours avoir un consommateur (`rallly`).
