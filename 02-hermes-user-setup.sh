#!/usr/bin/env bash
# 02-hermes-user-setup.sh — Installation de Hermes Agent (utilisateur non-root).
# À exécuter EN TANT QUE 'hermes' (PAS root) sur le VPS :
#   su - hermes
#   bash 02-hermes-user-setup.sh
#
# Installe le runtime Hermes dans ~/.hermes (même layout que l'app desktop).
set -euo pipefail

log() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Ne pas lancer en root. Fais 'su - hermes' d'abord." >&2
  exit 1
fi

log "Installation de Hermes Agent (installeur officiel)"
# Méthode documentée. Si tu préfères auditer avant : télécharge le script,
# lis-le, puis exécute-le manuellement.
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

log "Rechargement du shell"
# shellcheck disable=SC1090
source ~/.bashrc 2>/dev/null || true

log "Diagnostic"
~/.local/bin/hermes doctor || true

cat <<'EOF'

============================================================
 HERMES INSTALLÉ.
 Étapes interactives suivantes (en tant que 'hermes') :

 1) PROVIDER LLM — Nous Portal (comme en local) :
      hermes setup --portal        # OAuth : même compte Nous
      hermes portal status         # vérifier : "logged in" + Nous inference

 2) MESSAGING (Telegram) :
      hermes gateway setup         # colle le token bot Telegram + home channel
    NE PAS faire un simple 'hermes gateway install' : le user hermes n'a pas de
    sudo -> service USER + linger obligatoire (piège du bus). Voir README §6.
    (Slack : reporté, voir README §9.)

 3) DASHBOARD (pour l'app desktop via Tailscale) :
    - Renseigner les identifiants dans ~/.hermes/.env (voir README, §7)
    - Installer le service : voir hermes-dashboard.service + README §7

 4) Vérifier que tout tourne :
      systemctl --user status hermes-gateway   # ou voir README selon le mode d'install
============================================================
EOF
