#!/usr/bin/env bash
# Crée .env à partir de .env.example, chaque secret vide étant remplacé par une valeur aléatoire.
#   ./scripts/init-env.sh                  # local : DOMAIN=localhost
#   ./scripts/init-env.sh 10-0-12-34.sslip.io   # VM Énov (voir docs/vm.md)
# Ne remplace jamais un .env existant. Portable macOS (BSD) et Linux (GNU).
set -euo pipefail
cd "$(dirname "$0")/.."

[ -e .env ] && { echo ".env existe déjà : rien à faire (supprimez-le pour le régénérer)." >&2; exit 1; }

domain="${1:-localhost}"
umask 077
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    DOMAIN=*) printf 'DOMAIN=%s\n' "$domain" ;;
    [A-Z]*=) printf '%s%s\n' "$line" "$(openssl rand -base64 36 | tr -d '\n/+=')" ;;
    *) printf '%s\n' "$line" ;;
  esac
done < .env.example > .env

echo ".env créé (DOMAIN=${domain}, permissions 600)."
echo "Mot de passe des comptes de démo : grep ^DEMO_PASSWORD= .env"
