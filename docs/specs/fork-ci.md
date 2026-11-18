# CI/CD du fork Rallly — build, tests, scan, image GHCR

Porteur : César (pilier CI/CD de la note de cadrage, jalon J4) · Dépôt : `les-salopards/rallly` · Spec du 18/11/2026.

## Pourquoi
Critère de réussite n° 6 du sujet : « pipeline CI/CD avec preuve verte » sur la branche principale, avec au minimum le
build des images et, idéalement, tests et scan ; publication d'artefact documentée. C'est aussi ce qui débloque la démo :
sans image du fork, le Compose tourne avec `lukevella/rallly`, qui ignore la #1, la feature libre et la #7, et la VM
n'a rien à tirer.

## Existant
- `projet-infra` : `security-scan.yml` vert sur `main` (Trivy, contrôle du Compose, gitleaks), appelable en
  `workflow_call` avec `images: <image>`.
- Fork : les Actions sont activées au niveau du dépôt, mais les workflows upstream n'ont **jamais tourné**, même sur
  les 3 PR mergées le 18/11 (verrou propre aux forks). `ci.yml` (PR et push `main`) contient type-check, sherif, lint, tests unitaires, smoke test Docker avec
  Playwright, tests d'intégration. `docker-image.yml` publie sur Docker Hub (secrets absents chez nous), sur tag `v*`.
  `release.yml`, `db-backup.yml`, `delete-stale-preview-branches.yml`, `subprocessor-notice.yml` sont propres à l'équipe
  Rallly.
- `main` du fork protégée : 1 relecture requise, sans contrôle de statut obligatoire ; César est admin.

## Approche retenue (une seule sensée)
Un workflow à nous, `.github/workflows/image.yml`, et les workflows upstream inutiles désactivés.
Écarté : réutiliser `docker-image.yml` (multi-arch avec runners arm, Docker Hub, déclenché sur tag : trop d'écarts) ;
garder `ci.yml` entier (Playwright et intégration trop longs et fragiles la veille de la soutenance).

## Ce que fait `image.yml`
Déclenchement : `pull_request` vers `main`, `push` sur `main`, `workflow_dispatch`.
1. **check** : `pnpm install`, les contrôles statiques du job `linting` upstream (`pnpm turbo check` pour Biome,
   `check:structure`, `check:locales`, `check:cascades`), `pnpm db:generate`, `pnpm type-check`, `pnpm test:unit`
   (setup existant : `./.github/actions/setup-node` et `pnpm-install`).
2. **image** (après check) : build de `apps/web/Dockerfile` en `linux/amd64` (la VM Énov est x86), build-args
   `SELF_HOSTED=true` et `APP_VERSION=<sha court>`, cache GitHub Actions.
   - Sur PR : build seul, sans push.
   - Sur `main` : push sur `ghcr.io/les-salopards/rallly` avec les tags `sha-<sha court>` et `latest`
     (`GITHUB_TOKEN`, permission `packages: write`).
3. **scan** (après image, sur `main`) : appel de `les-salopards/projet-infra/.github/workflows/security-scan.yml@main`
   avec `images: ghcr.io/les-salopards/rallly:sha-<sha court>`.

## Autour du workflow
- Désactiver côté GitHub (API `actions/workflows/<id>/disable`, sans supprimer les fichiers pour garder le fork
  identique à upstream) `docker-image.yml`, `release.yml`, `db-backup.yml`, `delete-stale-preview-branches.yml`,
  `subprocessor-notice.yml` et `ci.yml` (remplacé par `image.yml` ; ses jobs Playwright et intégration sont hors
  périmètre ce soir). Fait le 18/11.
- Corriger l'exemple en tête de `security-scan.yml` (`projet-infra`) : tag `sha-<sha court>`, pas `${{ github.sha }}`.
- Rendre le package GHCR **public** (dépôt public, la VM tire sans authentification).
- `projet-infra` : `.env.example` et README pointent vers `ghcr.io/les-salopards/rallly:latest` pour la démo ;
  `docs/vm.md` garde le tag `sha-…` pour un déploiement reproductible.

## Hors périmètre
- Multi-arch (arm64), signature d'image, SBOM.
- Déploiement automatique sur la VM (joignable seulement par VPN : déploiement manuel documenté dans `docs/vm.md`).
- Tests Playwright et d'intégration upstream.

## Laissé au constructeur
- Découpage exact des jobs et des étapes, nom des jobs, versions d'actions.
- Si le scan remonte une CVE CRITICAL corrigeable dans l'image du fork : la corriger si c'est rapide, sinon l'accepter
  dans `.trivyignore.yaml` de `projet-infra` avec justification et date d'expiration (règle déjà en place).

## Vérification
- Run vert sur une PR (check + build) puis sur `main` (check + push + scan) ; capture pour les slides.
- `docker pull ghcr.io/les-salopards/rallly:latest` sans authentification.
- Stack `projet-infra` avec `RALLLY_IMAGE=ghcr.io/les-salopards/rallly:latest` : tout healthy en `read_only`
  (point non vérifié de la PR #3), démos #1 et feature libre rejouées.

## Vérifié (18/11/2026)
- Workflow `image.yml` mergé dans le fork (PR #4). Workflows upstream désactivés via l'API (fichiers conservés).
- Sur PR (#5, #6) : lint, type-check, tests unitaires et build de l'image verts.
- Premier run sur `main` : image publiée, mais **scan rouge** sur 3 CVE CRITICAL corrigeables de dépendances upstream
  (GHSA-2464-fhr4-w9xw et GHSA-673q-mjm6-r5xr sur `next` 16.3.8, CVE-2026-25896 sur `fast-xml-parser` 5.3.4).
  Corrigées par la PR #6 (`next` 16.4.1, override `fast-xml-parser` `^5.5.6`) plutôt qu'acceptées.
- Run sur `main` après #5 et #6 (commit `211bb223`, après la réécriture d'historique de Raph) : **tout vert**, scan
  compris. Image `ghcr.io/les-salopards/rallly:latest` = #1 + feature libre + #7.
- L'image du fork tourne en `read_only` dans la stack (Rallly healthy, migrations appliquées, démo #7 jouée).
- **Reste à faire** : rendre le package GHCR public (aujourd'hui un `docker pull` anonyme répond `unauthorized`).
