#!/usr/bin/env bash
# End-to-end smoke test of the local stack. Run from anywhere: scripts/smoke.sh
# Needs a filled .env, plus bash, curl and docker only. Stops at the first failing check.
set -euo pipefail
cd "$(dirname "$0")/.."

ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; exit 1; }
# Read VAR from .env without sourcing it (never execute .env as shell)
val()  { sed -n "s/^$1=//p" .env | tail -n 1; }

[ -f .env ] || fail "missing .env (cp .env.example .env, then generate the secrets, see README)"
DOMAIN=$(val DOMAIN); DOMAIN=${DOMAIN:-localhost}
IP=${SMOKE_IP:-127.0.0.1} # where caddy publishes 80/443
CA=$(mktemp); trap 'rm -f "$CA"' EXIT

# HTTP status of https://<host><path>, trusting Caddy's local CA
code() {
  local host=$1 path=$2; shift 2
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert "$CA" \
    --resolve "$host:443:$IP" "$@" "https://$host$path"
}
# HTTPS request to <url> from inside the rallly container. Any HTTP answer passes:
# the check is DNS (network alias -> caddy) + TLS trust of Caddy's CA, both needed by OIDC in J2.
hairpin() {
  docker compose exec -T rallly node -e '
    fetch(process.argv[1]).catch(e => { console.error(e.cause?.code || e.message); process.exit(1) })' "$1"
}

echo "== env guard"
out=$(docker compose --env-file .env.example config -q 2>&1) \
  && fail "compose accepts .env.example with empty secrets"
grep -q "is missing a value" <<<"$out" || fail "unexpected compose error: $out"
ok "compose refuses empty secrets ($(grep -o 'required variable [A-Z_]*' <<<"$out" | head -n 1))"

echo "== stack up"
docker compose up -d --wait --wait-timeout 300 >/dev/null 2>&1 \
  || { docker compose ps -a; fail "docker compose up --wait"; }
ok "all services healthy"

echo "== exposure"
ports=$(docker compose ps --format '{{range .Publishers}}{{if .PublishedPort}}{{.PublishedPort}} {{end}}{{end}}' \
  | tr ' ' '\n' | { grep . || true; } | sort -un | paste -sd, -)
[ "$ports" = "80,443" ] || fail "published host ports are '$ports', expected '80,443'"
ok "only 80,443 published"

docker compose exec -T caddy cat /data/caddy/pki/authorities/local/root.crt >"$CA"
grep -q "BEGIN CERTIFICATE" "$CA" || fail "could not read Caddy root CA"

c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "mail.$DOMAIN:80:$IP" "http://mail.$DOMAIN/")
[ "$c" = 308 ] || fail "http://mail.$DOMAIN -> $c, expected 308 redirect to https"
ok "http redirects to https"

echo "== mailpit"
c=$(code "mail.$DOMAIN" /);               [ "$c" = 401 ] || fail "mailpit UI without auth -> $c, expected 401"
c=$(code "mail.$DOMAIN" /api/v1/messages); [ "$c" = 401 ] || fail "mailpit API without auth -> $c, expected 401"
c=$(code "mail.$DOMAIN" / -u "$(val MAILPIT_UI_AUTH)"); [ "$c" = 200 ] || fail "mailpit UI with auth -> $c, expected 200"
ok "mailpit UI and API locked behind basic auth"

echo "smoke: all checks passed"
