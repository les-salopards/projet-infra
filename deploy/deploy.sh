#!/usr/bin/env bash
# Met à jour et (re)démarre la stack sur la VM, puis vérifie qu'elle répond.
# À lancer en tant que `deploy` depuis la racine du dépôt : ./deploy/deploy.sh
# Les images viennent de GHCR (publiées par la CI) : la VM ne build rien.
set -euo pipefail

cd "$(dirname "$0")/.."

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[ -f .env ] || fail ".env absent : cp .env.example .env puis remplir les secrets."

# DOMAIN et les sous-domaines viennent du même .env que le Compose.
set -a; . ./.env; set +a
DOMAIN="${DOMAIN:?DOMAIN manquant dans .env}"
AUTH_HOST="${AUTH_HOST:-auth.${DOMAIN}}"
RALLLY_HOST="${RALLLY_HOST:-rallly.${DOMAIN}}"

if [ "${SKIP_PULL:-0}" != 1 ]; then
  log "Mise à jour du dépôt"
  git pull --ff-only
fi

log "Validation du Compose"
docker compose config --quiet

log "Téléchargement des images"
docker compose pull --quiet

log "Démarrage"
docker compose up -d --remove-orphans --wait --wait-timeout 300

log "Smoke tests (via Caddy, en résolvant les noms vers cette machine)"
check() {
  local name="$1" url="$2" host
  host="$(printf '%s' "$url" | sed -E 's#^https?://([^/]+).*#\1#')"
  if curl -fsS -k -o /dev/null --max-time 15 --resolve "${host}:443:127.0.0.1" --resolve "${host}:80:127.0.0.1" "$url"; then
    printf '   ok   %s\n' "$name"
  else
    printf '   KO   %s (%s)\n' "$name" "$url"; return 1
  fi
}
status=0
check "Authentik (discovery OIDC)" "https://${AUTH_HOST}/application/o/rallly/.well-known/openid-configuration" || status=1
check "Rallly (/api/status)" "https://${RALLLY_HOST}/api/status" || status=1

log "Ports publiés sur l'hôte (attendu : 80 et 443 uniquement)"
docker compose ps --format '{{.Service}}\t{{.Ports}}' | grep -E '0\.0\.0\.0|\[::\]' || true

docker image prune -f >/dev/null
[ "$status" = 0 ] && log "Déploiement OK" || fail "Smoke test en échec : docker compose logs --tail 100"
