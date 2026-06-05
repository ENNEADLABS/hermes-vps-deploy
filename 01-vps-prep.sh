#!/usr/bin/env bash
# 01-vps-prep.sh — Préparation OS du VPS (Hostinger KVM4, Ubuntu/Debian).
# À exécuter EN ROOT sur le VPS fraîchement provisionné :
#   ssh root@<ip-vps> 'bash -s' < 01-vps-prep.sh
# ou : scp ce fichier sur le VPS puis `sudo bash 01-vps-prep.sh`
#
# Idempotent : peut être relancé sans casse.
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"

log() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Ce script doit tourner en root (sudo)." >&2
  exit 1
fi

log "Mise à jour du système"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

log "Installation des dépendances de base"
apt-get install -y --no-install-recommends \
  curl ca-certificates git git-lfs ufw fail2ban \
  python3 python3-venv build-essential ffmpeg ripgrep jq unattended-upgrades

log "Mises à jour de sécurité automatiques"
dpkg-reconfigure -f noninteractive unattended-upgrades || true

log "Création de l'utilisateur non-root '$HERMES_USER'"
if ! id "$HERMES_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$HERMES_USER"
  usermod -aG sudo "$HERMES_USER"
  echo "Utilisateur '$HERMES_USER' créé (membre de sudo)."
else
  echo "Utilisateur '$HERMES_USER' déjà présent."
fi

log "Pare-feu UFW : SSH autorisé, tailnet autorisé, reste fermé"
ufw allow OpenSSH
# Anti-lockout : autorise tout le trafic entrant du tailnet (interface tailscale0).
# Le tailnet est privé (tes seuls appareils), donc c'est sûr ; ça garantit l'accès
# SSH via Tailscale et ouvre le dashboard (9119) sans règle supplémentaire.
if ip link show tailscale0 &>/dev/null; then
  ufw allow in on tailscale0
fi
ufw --force enable
ufw status verbose

log "Installation de Tailscale"
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "Tailscale déjà installé."
fi

cat <<'EOF'

============================================================
 PREP OS TERMINÉE.
 Étapes manuelles suivantes (toujours en root) :

 1) Connecter le VPS au tailnet :
       tailscale up --ssh
    -> ouvre l'URL affichée dans ton navigateur et valide.
    Récupère l'IP tailscale (100.x.y.z) :
       tailscale ip -4

    (Le dashboard sur 9119 est déjà couvert : UFW autorise TOUT le trafic
     entrant de tailscale0. Pas de règle par port à ajouter.)

 2) Passer sur l'utilisateur hermes pour la suite :
       su - hermes
    puis lancer 02-hermes-user-setup.sh
============================================================
EOF
