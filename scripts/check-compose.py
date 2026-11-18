#!/usr/bin/env python3
"""Vérifie les règles de durcissement sur le Compose résolu (docker compose config --format json).

Usage : docker compose config --format json | python3 scripts/check-compose.py
Code de sortie 1 si une règle est violée. Règles et exceptions justifiées : docs/security.md.
"""
import json
import sys

# Seul point d'entrée de la stack
PUBLISHED_OK = {"caddy": {"80", "443"}}
# Capacités ajoutées, une par une, avec leur justification dans docs/security.md
CAP_ADD_OK = {"caddy": {"NET_BIND_SERVICE"}, "caddy-ca": {"DAC_OVERRIDE"}}
# Services qui ne tournent pas sous un utilisateur non-root explicite
ROOT_OK = {"caddy-ca"}  # one-shot sans réseau, copie un certificat public puis s'arrête
# Services dont l'image fixe déjà un USER non-root (vérifié à l'exécution, voir docs/security.md)
IMAGE_USER = {"authentik-server", "authentik-worker", "rallly"}
DB_SERVICES = {"authentik-db", "rallly-db"}

cfg = json.load(sys.stdin)
services, networks = cfg["services"], cfg.get("networks", {})
errors = []

for name, s in sorted(services.items()):
    def err(msg):
        errors.append(f"{name}: {msg}")

    if "ALL" not in [c.upper() for c in s.get("cap_drop", [])]:
        err("cap_drop: [ALL] manquant")
    extra = {c.upper() for c in s.get("cap_add", [])} - CAP_ADD_OK.get(name, set())
    if extra:
        err(f"capacités non justifiées : {sorted(extra)}")
    if not any(o.replace(" ", "").startswith("no-new-privileges") for o in s.get("security_opt", [])):
        err("security_opt no-new-privileges manquant")
    if not s.get("read_only"):
        err("read_only: true manquant")
    if s.get("privileged"):
        err("privileged interdit")
    user = str(s.get("user", ""))
    if name not in ROOT_OK and name not in IMAGE_USER and user in ("", "root", "0", "0:0"):
        err(f"utilisateur non-root explicite manquant (user: {user or 'absent'})")
    published = {str(p.get("published")) for p in s.get("ports", []) if p.get("published")}
    if published - PUBLISHED_OK.get(name, set()):
        err(f"ports publiés non autorisés : {sorted(published)}")
    if any("docker.sock" in str(v.get("source", "")) for v in s.get("volumes", [])):
        err("docker.sock monté")
    if name in DB_SERVICES:
        nets = s.get("networks", {})
        open_nets = [n for n in nets if not networks.get(n, {}).get("internal")]
        if open_nets:
            err(f"base de données sur un réseau non internal : {open_nets}")

if errors:
    print("   ÉCHEC durcissement Compose :")
    for e in errors:
        print("   -", e)
    sys.exit(1)
print(f"   ok  {len(services)} services : cap_drop ALL, no-new-privileges, read_only, "
      "ports 80/443 sur caddy uniquement, bases sur réseaux internal")
