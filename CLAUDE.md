# projet-infra

Infra du projet M2 « Dev avec Docker » (Ynov 2026-2027) : environnement local + VM Énov avec reverse proxy, Authentik (OIDC) devant Rallly, CI/CD verte, 3 features Rallly.

## Références
- Note de cadrage (équipe, rôles, jalons J1–J4, risques) : https://claude.ai/code/artifact/830575ec-211c-4244-ae00-1563011efb58
- Sujet officiel : `~/projects/scolaire/M2-docker/2026-2027 - Sujet projet - Dev avec Docker.pdf`
- Fork Rallly (code des features uniquement) : `../rallly` (`git@github.com:les-salopards/rallly.git`)

## Découpage des dépôts
- Ce dépôt : Compose, config proxy et Authentik, `.env.example`, workflows CI, README, schéma d'archi, `docs/specs/` (specs de features).
- Le fork `rallly` ne reçoit jamais de fichier d'infra ni nos ajouts de méthode (il a déjà son propre `CLAUDE.md` versionné).

## Exigences du sujet à garder en tête
- Clone + README + `docker compose up` doivent suffire.
- Secrets hors image et hors dépôt : `.env` gitignoré, `.env.example` commité.
- Point d'entrée unique via le proxy ; Postgres jamais exposé sur l'hôte.
- Durcissement : non-root, surface réduite, scan commenté.
- Même Compose en local et sur la VM, écarts documentés.

## Commandes
- `cp .env.example .env` puis remplir les secrets
- `docker compose up -d` / `docker compose ps` / `docker compose logs -f <service>`
- `docker compose config -q` pour valider le Compose

## Conventions
- Docs et README en français ; code, identifiants, commits en anglais.
- Pièges (redirect URI OIDC, SMTP, DNS, certificats) notés dans le README au fil de l'eau.

Ce projet suit la **méthode complète** : avant tout nouveau projet, nouvelle feature ou changement de comportement, invoque le skill `methode-complete`.
