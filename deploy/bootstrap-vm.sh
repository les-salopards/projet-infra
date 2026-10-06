#!/usr/bin/env bash
# Prépare une VM Énov (OpenNebula) pour héberger la stack.
# À lancer une fois en root : `ssh root@<IP> 'bash -s' < deploy/bootstrap-vm.sh`
# Idempotent : on peut le relancer sans casser l'existant.
#
# Ce qu'il fait :
#   1. installe Docker Engine + plugin Compose (dépôt officiel Docker) ;
#   2. crée l'utilisateur non-root `deploy` (groupe docker) avec les clés SSH de root ;
#   3. pare-feu : seuls 22, 80 et 443 entrants ;
#   4. SSH : clé uniquement, plus de login root ;
#   5. mises à jour de sécurité automatiques ;
#   6. clone le dépôt dans /opt/projet-infra.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
REPO_URL="${REPO_URL:-https://github.com/les-salopards/projet-infra.git}"
APP_DIR="${APP_DIR:-/opt/projet-infra}"
# Laisser LOCK_ROOT=0 tant que la connexion en `deploy` n'a pas été testée.
LOCK_ROOT="${LOCK_ROOT:-0}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "À lancer en root." >&2; exit 1; }

. /etc/os-release
case "${ID} ${ID_LIKE:-}" in
  *debian*|*ubuntu*) FAMILY=debian ;;
  *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) FAMILY=rhel ;;
  *) echo "Distribution non gérée : ${ID}" >&2; exit 1 ;;
esac
log "Distribution : ${PRETTY_NAME} (${FAMILY})"

# --- 1. Docker -----------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker"
  if [ "$FAMILY" = debian ]; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl git
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    dnf -y -q install dnf-plugins-core git curl
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf -y -q install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
else
  log "Docker déjà installé : $(docker --version)"
fi

# Rotation des logs + pas de nouveaux privilèges par défaut pour tous les conteneurs.
mkdir -p /etc/docker
DAEMON_CHANGED=0
if [ ! -f /etc/docker/daemon.json ]; then
  DAEMON_CHANGED=1
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "no-new-privileges": true,
  "live-restore": true
}
JSON
fi
systemctl reset-failed docker 2>/dev/null || true
systemctl enable --now docker
# Redémarrer seulement si la config a changé : des redémarrages en rafale
# déclenchent le start-limit de systemd et laissent Docker arrêté.
if [ "$DAEMON_CHANGED" = 1 ]; then systemctl restart docker; fi
docker info >/dev/null

# --- 2. Utilisateur deploy ----------------------------------------------
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  log "Création de l'utilisateur ${DEPLOY_USER}"
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh"
if [ -f /root/.ssh/authorized_keys ]; then
  # Les clés ajoutées dans Nebula sont injectées pour root : on les réutilise.
  install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /root/.ssh/authorized_keys "/home/${DEPLOY_USER}/.ssh/authorized_keys"
fi

# --- 3. Pare-feu ---------------------------------------------------------
# Docker publie ses ports via iptables et passe devant ufw/firewalld : la vraie
# barrière est donc de ne publier que 80/443 dans le Compose (aucune BDD exposée).
log "Pare-feu : 22, 80, 443"
if [ "$FAMILY" = debian ]; then
  apt-get install -y -qq ufw
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
else
  dnf -y -q install firewalld
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service=ssh --add-service=http --add-service=https >/dev/null
  firewall-cmd --reload >/dev/null
fi

# --- 4. SSH --------------------------------------------------------------
log "SSH : clé uniquement"
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-hardening.conf
mkdir -p /etc/ssh/sshd_config.d
{
  echo "PasswordAuthentication no"
  echo "KbdInteractiveAuthentication no"
  if [ "$LOCK_ROOT" = 1 ]; then echo "PermitRootLogin no"; else echo "PermitRootLogin prohibit-password"; fi
} > "$SSHD_DROPIN"
# Ubuntu 24.04 active sshd par socket : /run/sshd n'existe pas avant la 1re connexion.
mkdir -p /run/sshd
sshd -t
for unit in ssh sshd; do systemctl try-reload-or-restart "$unit" 2>/dev/null || true; done

# --- 5. Mises à jour automatiques --------------------------------------
log "Mises à jour de sécurité automatiques"
if [ "$FAMILY" = debian ]; then
  apt-get install -y -qq unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades
else
  dnf -y -q install dnf-automatic
  sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
  systemctl enable --now dnf-automatic.timer
fi

# --- 6. Dépôt ------------------------------------------------------------
if [ ! -d "${APP_DIR}/.git" ]; then
  log "Clone de ${REPO_URL} dans ${APP_DIR}"
  git clone -q "$REPO_URL" "$APP_DIR"
fi
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"

log "Terminé. Étape suivante :"
echo "  ssh ${DEPLOY_USER}@<IP>"
echo "  cd ${APP_DIR} && cp .env.example .env && \$EDITOR .env && ./deploy/deploy.sh"
