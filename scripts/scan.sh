#!/usr/bin/env bash
# Scan de sécurité de la stack, sans rien installer : chaque outil tourne dans un conteneur.
#   ./scripts/scan.sh                 # images du Compose + config + Dockerfiles + secrets
#   ./scripts/scan.sh image1 image2   # seulement ces images
# Rapports : reports/ (gitignoré). Commentaires des résultats : docs/security.md.
# Code de sortie ≠ 0 si une CVE CRITICAL corrigeable ou un secret est trouvé (utilisable en CI).
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
mkdir -p reports .trivy-cache

TRIVY="aquasec/trivy:0.75.0"
HADOLINT="hadolint/hadolint:v2.15.1"
GITLEAKS="zricethezav/gitleaks:v8.30.1"
SEVERITY="${SEVERITY:-HIGH,CRITICAL}"
status=0

trivy() {
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$PWD/.trivy-cache:/root/.cache/trivy" \
    -v "$PWD:/src:ro" -v "$PWD/reports:/reports" -w /src \
    "$TRIVY" "$@"
}

if [ "$#" -gt 0 ]; then
  images=("$@")
elif ls compose*.y*ml >/dev/null 2>&1; then
  images=()
  # bash 3.2 (macOS) n'a pas mapfile.
  while IFS= read -r line; do images+=("$line"); done < <(docker compose config --images 2>/dev/null | sort -u)
else
  images=()
fi

echo "== Images (${SEVERITY}, vulnérabilités corrigeables uniquement)"
for image in ${images[@]+"${images[@]}"}; do
  safe="$(printf '%s' "$image" | tr '/:@' '___')"
  # Image publiée : on prend la dernière version. Image construite localement (CI) : on la garde.
  docker pull -q "$image" >/dev/null 2>&1 || docker image inspect "$image" >/dev/null 2>&1 \
    || { echo "   image introuvable : $image"; status=1; continue; }
  trivy image --quiet --scanners vuln --ignore-unfixed --severity "$SEVERITY" \
    --format table --output "/reports/image-${safe}.txt" "$image"
  trivy image --quiet --scanners vuln --ignore-unfixed --severity "$SEVERITY" \
    --format json --output "/reports/image-${safe}.json" "$image"
  if [ ! -s "reports/image-${safe}.json" ]; then
    echo "   ERREUR : pas de rapport pour $image"; status=1; continue
  fi
  counts="$(python3 -c 'import json,sys
d=json.load(sys.stdin); c={"CRITICAL":0,"HIGH":0}
for r in d.get("Results",[]):
  for v in r.get("Vulnerabilities") or []: c[v["Severity"]]=c.get(v["Severity"],0)+1
print(c["CRITICAL"], c["HIGH"])' < "reports/image-${safe}.json")"
  read -r crit high <<<"$counts"
  printf '   %-60s CRITICAL=%s HIGH=%s\n' "$image" "$crit" "$high"
  [ "$crit" -gt 0 ] && status=1
done

echo "== Config (Compose, Dockerfiles) : erreurs de configuration"
trivy config --quiet --severity "$SEVERITY" --format table --output /reports/config.txt . \
  && echo "   reports/config.txt"

echo "== Dockerfiles (hadolint)"
find . -name 'Dockerfile*' -not -path './node_modules/*' -not -path './.git/*' | while read -r f; do
  docker run --rm -i "$HADOLINT" < "$f" > "reports/hadolint-$(echo "$f" | tr '/.' '__').txt" \
    && echo "   ok  $f" || echo "   avertissements : $f (voir reports/)"
done

echo "== Secrets (gitleaks, tout l'historique Git)"
if docker run --rm -v "$PWD:/repo:ro" "$GITLEAKS" git /repo --redact --no-banner \
     --report-format json --report-path /dev/stdout > reports/gitleaks.json 2>/dev/null; then
  echo "   aucun secret détecté"
else
  echo "   SECRET DÉTECTÉ : reports/gitleaks.json"; status=1
fi

exit "$status"
