# Authentik : SSO, policies par groupe, invitation externe

Toute la configuration est déclarée dans [authentik/blueprints/rallly.yaml](../authentik/blueprints/rallly.yaml),
appliquée automatiquement par le worker au `docker compose up` (et à chaque modification du fichier).
Rien n'est à cliquer dans l'admin : une stack neuve, locale ou VM, a la même config.
Vérification : Admin → *Personnalisation → Blueprints* → `projet-infra - Rallly`, statut *successful*.

## 1. SSO Rallly (OIDC)

| Élément | Valeur |
| --- | --- |
| Provider | OAuth2/OIDC `Rallly`, client confidentiel, `client_id` = `rallly`, secret = `RALLLY_OIDC_CLIENT_SECRET` |
| Application | slug `rallly` → issuer `https://auth.<DOMAIN>/application/o/rallly/` |
| Redirect URI | `https://rallly.<DOMAIN>/api/auth/callback/oidc` (strict) |
| Scopes | `openid`, `email`, `profile` (ce dernier contient le claim `groups`) |
| Signature | RS256, certificat auto-signé d'Authentik |
| Consentement | implicite (pas d'écran « autoriser Rallly ») |

Côté Rallly ([compose.yml](../compose.yml)) : `OIDC_DISCOVERY_URL`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`,
et `EMAIL_LOGIN_ENABLED=false` : la page de login redirige directement vers Authentik.

**Démo** : ouvrir `https://rallly.<DOMAIN>` → redirection vers Authentik → `alice` + mot de passe → retour dans Rallly, connectée
avec le nom et l'e-mail venant d'Authentik.

### Pièges rencontrés
- **Redirect URI** : Rallly (Better Auth) envoie `/api/auth/callback/oidc`, pas `/api/better-auth/...`. Elle doit correspondre
  exactement à `NEXT_PUBLIC_BASE_URL` : sur la VM, c'est le `DOMAIN` du `.env` qui la fait changer.
- **Rallly appelle Authentik par l'URL publique** (l'issuer doit être le même que dans le navigateur) : alias réseau
  `auth.<DOMAIN>` sur Caddy et CA de Caddy fournie à Node via `NODE_EXTRA_CA_CERTS`. Si la discovery échoue au démarrage,
  Rallly désactive le provider (`Provider "oidc" ... skipped` dans ses logs) : d'où `depends_on: authentik-server (healthy)`.
- **`grant_types` obligatoires** depuis Authentik 2026 : sans `authorization_code`, l'autorisation échoue avec
  « The request is otherwise malformed » (log Authentik : `Invalid grant_type for provider`).

## 2. Policies par groupe

| Groupe | Droits Authentik | Accès Rallly |
| --- | --- | --- |
| `rallly-admins` | superuser : comptes, groupes, invitations | autorisé |
| `rallly-users` | aucun (portail utilisateur seulement) | autorisé |
| *(aucun groupe)* | aucun | **refusé** |

Deux *policy bindings* de groupe sur l'application `rallly` (mode `any`) : il suffit d'être dans l'un des deux groupes.
Le refus a lieu dans Authentik, avant tout retour vers Rallly : aucun compte n'est créé côté Rallly.

**Démo** : se connecter à Rallly en `charlie` → page Authentik « Permission denied ». En `bob`, montrer en plus l'accès
à l'admin Authentik, que `alice` n'a pas.

## 3. Invitation d'un utilisateur externe

Flow `rallly-invitation` (inscription) :

1. **Invitation** : refuse l'accès sans jeton d'invitation valide ;
2. **Formulaire** : identifiant, nom, e-mail, mot de passe ;
3. **Création du compte** : type *external*, rangé dans `users/external`, ajouté au groupe `rallly-users` ;
4. **Connexion** automatique.

**Démo**
1. En `bob` (ou `akadmin`) : Admin → *Annuaire → Invitations → Créer*. Nom `invite-demo`, flow `rallly-invitation`,
   cocher *Usage unique*, éventuellement une date d'expiration.
2. Déplier l'invitation et copier le lien (`https://auth.<DOMAIN>/if/flow/rallly-invitation/?itoken=...`),
   puis l'envoyer à l'invité (e-mail, chat).
3. Navigation privée : ouvrir le lien, remplir le formulaire → compte créé et connecté.
4. Ouvrir `https://rallly.<DOMAIN>` → l'invité entre directement dans Rallly.
5. Rouvrir le même lien → refusé (usage unique). Le flow sans `itoken` est refusé aussi.

## Comptes de démo

`alice`, `bob`, `charlie`, avec le mot de passe `DEMO_PASSWORD` du `.env` (le mot de passe est réappliqué à chaque
application du blueprint). Admin Authentik : `akadmin` / `AUTHENTIK_BOOTSTRAP_PASSWORD`.
