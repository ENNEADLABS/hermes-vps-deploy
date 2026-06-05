# Déploiement Hermes Agent sur VPS Hostinger + Tailscale — Runbook

Procédure **réelle et testée** pour faire tourner Hermes Agent 24/7 sur un VPS Hostinger
(KVM4, Ubuntu 24.04 LTS), piloté depuis l'app desktop macOS et depuis Telegram, le tout
via un tailnet privé : **aucun port applicatif exposé sur internet** (dashboard et gateway
joignables uniquement par le tailnet). Seul le SSH (22) reste ouvert publiquement, comme
filet anti-lockout — voir §Sécurité.

> Statut de ce déploiement : **opérationnel**. Telegram + dashboard + app desktop OK.
> Slack reporté (limite du workspace gratuit) — voir §9.

## Architecture obtenue

```
[Mac : app desktop Hermes] ──tailnet (privé, chiffré)──► [VPS Hostinger KVM4 / Ubuntu 24.04]
                                                          ├─ hermes-dashboard (service systemd SYSTEM)
                                                          │    bind 0.0.0.0:9119, basic-auth, accès tailnet only
                                                          ├─ hermes-gateway (service systemd USER + linger)
                                                          │    Telegram (polling), 24/7
                                                          └─ agent core : provider Nous Portal,
                                                               backend terminal local, ~/.hermes (user hermes)
```

- **Aucun port _applicatif_ exposé** : UFW n'autorise en entrée que SSH (22, filet anti-lockout) et tout `tailscale0`. Dashboard (`9119`) et gateway ne passent que par le tailnet.
- **SSH sans mot de passe ni clé** : Tailscale SSH (`tailscale up --ssh`).
- **App desktop** : se connecte au dashboard distant via le tailnet (Remote gateway).

Décisions d'architecture et leur justification : voir `docs/decisions/0001-deploiement-hermes-vps-hostinger.md`.

---

## Valeurs spécifiques à ce déploiement

| Élément | Valeur |
|---|---|
| VPS hostname | `<VPS_HOSTNAME>` (ex. `srvXXXXXX`) |
| VPS IPv4 publique | `<VPS_PUBLIC_IP>` (jamais utilisée pour l'accès — tout passe par le tailnet) |
| VPS IP tailscale | `<VPS_TS_IP>` (= `$VPS` dans les commandes ci-dessous) |
| Mac IP tailscale | `<MAC_TS_IP>` |
| User applicatif (non-root) | `hermes` |
| UID du user `hermes` | `1001` (vérifie avec `id -u hermes` — conditionne `/run/user/<UID>` dans toutes les commandes `systemctl --user`) |
| Provider LLM | Nous Portal (OAuth) |
| Modèle | `nvidia/nemotron-3-ultra:free` (gratuit — compte sans crédits payants) |
| Dashboard | `http://<VPS_TS_IP>:9119`, login `admin` / basic-auth |

Remplace ces placeholders par tes valeurs. Astuce pour copier-coller les commandes :
`export VPS=<ton-ip-tailscale-vps>` — toutes les commandes ci-dessous utilisent alors `$VPS`.

---

## Pré-requis

- VPS Hostinger avec **Ubuntu 24.04 LTS** (réinstallable depuis le panel Hostinger).
- Accès **console web Hostinger** (terminal navigateur) — sert d'accès hors-bande initial.
- Compte **Tailscale** (gratuit, plan Personal).
- Sur le Mac : **Homebrew**, et un compte **Nous Portal** déjà utilisé en local.
- Pour Telegram : un bot (BotFather) + ton user-id Telegram.

---

## 0. (Annexe) Assainir un VPS existant qui a dormi

Si le VPS a déjà servi / dormi longtemps, avant d'installer Hermes :

```bash
# Diagnostic (lecture seule)
grep PRETTY_NAME /etc/os-release; uptime; df -h /; free -h
apt list --upgradable 2>/dev/null | wc -l
[ -f /var/run/reboot-required ] && echo "reboot requis"

# Mise à jour complète (non-interactive, gère needrestart + conflits de config)
export DEBIAN_FRONTEND=noninteractive
apt-get update
NEEDRESTART_MODE=a apt-get -y -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" full-upgrade
reboot      # si un nouveau kernel a été installé

# Après reboot : purge des vieux kernels (résidus rc) + cache apt
dpkg -l | awk '/^rc/ {print $2}' | xargs -r apt-get -y purge
apt-get -y --purge autoremove && apt-get autoclean
```

Désinstaller d'anciens services (ex. Docker/n8n) si inutiles — voir l'historique de session.
Penser au binaire orphelin `/usr/bin/docker` (hors apt) : `command -v docker` ment via le cache
shell après suppression → faire `hash -r` pour vérifier.

---

## 1. Tailscale (Mac + VPS)

**Sur le Mac :**
```bash
brew install --cask tailscale
open -a Tailscale          # puis "Log in" depuis l'icône de la barre de menu
```
Le CLI macOS de l'app : `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

**Sur le VPS (dans la console web Hostinger, en root) :**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --ssh        # ouvre l'URL d'auth -> valide avec LE MÊME compte
tailscale ip -4           # note l'IP tailscale du VPS (100.x.y.z)
```

`--ssh` active **Tailscale SSH** : ensuite tu te connectes depuis le Mac sans mot de passe ni clé.

> ⚠️ **Désactive l'expiration de clé du nœud VPS.** Par défaut Tailscale expire la clé d'un nœud
> après ~180 jours : le VPS sortirait alors du tailnet et tu perdrais l'accès dashboard + SSH-via-tailnet
> (il ne resterait que le 22 public et la console Hostinger). Console admin Tailscale → machine du VPS
> → menu `⋯` → **Disable key expiry**. Indispensable pour un déploiement 24/7.

## 2. SSH propre depuis le Mac

```bash
ssh root@$VPS    # 1re fois : valider la host key + éventuel check Tailscale dans le navigateur
```
Plus besoin de la console web Hostinger (qui reste le filet de sécurité hors-bande).

## 3. Préparer l'OS (root)

```bash
scp ~/hermes-vps-deploy/*.sh ~/hermes-vps-deploy/hermes-dashboard.service root@$VPS:/root/
ssh root@$VPS 'bash /root/01-vps-prep.sh'
```
`01-vps-prep.sh` : maj système, dépendances, **user non-root `hermes`** (groupe sudo, sans mot de passe),
UFW (SSH + `tailscale0` autorisés, reste fermé), Tailscale.

> **Anti-lockout** : le script autorise `ufw allow in on tailscale0` AVANT d'activer UFW, pour ne
> jamais couper l'accès SSH-via-tailscale. La console web Hostinger reste le filet ultime.

## 4. Installer Hermes (user hermes)

`/root` n'étant pas lisible par `hermes`, on copie les scripts dans son home, puis on lance
l'install en **service transient détaché** (survit à la déconnexion SSH, ~2-3 min) :

```bash
ssh root@$VPS '
  cp /root/02-hermes-user-setup.sh /root/hermes-dashboard.service /home/hermes/
  chown hermes:hermes /home/hermes/02-hermes-user-setup.sh /home/hermes/hermes-dashboard.service
  systemd-run --uid=hermes --gid=hermes -p WorkingDirectory=/home/hermes \
    --setenv=HOME=/home/hermes \
    --setenv=PATH=/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin \
    --unit=hermes-install bash /home/hermes/02-hermes-user-setup.sh
'
# Suivre : journalctl -u hermes-install -f   (attendre "HERMES INSTALLÉ")
```

`02-hermes-user-setup.sh` lance l'installeur officiel (`curl … install.sh | bash`) qui pose
uv, Python 3.11, Node, et Hermes dans `~/.hermes`.

## 5. Provider LLM — Nous Portal (interactif, session SSH en tant que hermes)

```bash
ssh root@$VPS      # puis :
su - hermes
hermes setup --portal       # OAuth : ouvre l'URL affichée, login MÊME compte Nous
hermes model                # provider Nous Portal -> choisir un modèle
hermes portal status        # vérifier : Model = ✓ using Nous, Tool Gateway via Portal
```

> **Compte sans crédits** : les modèles payants (deepseek, grok, claude…) renvoient
> `requires available credits`. On a choisi un **modèle gratuit** : `nvidia/nemotron-3-ultra:free`
> (via le sélecteur de `hermes model`). Pour un payant : ajouter des crédits sur portal.nousresearch.com.
> Vérifier l'inférence : `hermes chat -q "Reply with exactly: PONG"`.

## 6. Gateway Telegram (24/7)

**Créer le bot** (Telegram) : `@BotFather` → `/newbot` → récupérer le **token** ;
`@userinfobot` → récupérer ton **user-id**.

**Configurer** (session SSH, user hermes) :
```bash
hermes gateway setup        # cocher Telegram (Espace) -> Done ; coller le token ; home channel = ton user-id
```

**Service systemd — IMPORTANT (piège du bus user) :**
Le user `hermes` n'a pas de mot de passe → pas de `sudo` → on installe un **service USER**
(`systemctl --user`), pas un service system. Mais `systemctl --user` échoue dans une session `su`
avec *« Failed to connect to bus: No medium found »*. Solution : activer le **linger** (en root),
ce qui démarre un bus systemd persistant pour `hermes` :

```bash
# en root :
loginctl enable-linger hermes
# puis (en root, avec l'env du bus user) :
su - hermes -c 'export XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus; \
  hermes gateway install; systemctl --user enable --now hermes-gateway; \
  systemctl --user status hermes-gateway --no-pager | head'
```

Vérifier : `~/.hermes/logs/gateway.log` doit montrer *« ✓ telegram connected »*.

**Sécurité Telegram** : par défaut Hermes **refuse tout user hors allowlist** (deny-by-default).
Le owner (home channel = ton user-id) est auto-autorisé ; les inconnus reçoivent un **code de
pairing** à approuver via `hermes pairing approve telegram <CODE>`. Le bot n'est donc pas public.

## 7. Dashboard pour l'app desktop (service system, root)

**Credentials basic-auth** (user hermes, secret — à faire soi-même) :
```bash
umask 077
PW=$(openssl rand -base64 18)
{
  echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin"
  echo "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$PW"
  echo "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -base64 32)"
} >> ~/.hermes/.env
chmod 600 ~/.hermes/.env
echo "==> NOTE CE MOT DE PASSE (app desktop) : $PW"
```

**Pré-build du web UI** : `hermes dashboard` build automatiquement le web UI au 1er lancement
(tsc + vite → `hermes_cli/web_dist/`, ~70 s). On le fait une fois, puis on lance le service avec
`--skip-build` (démarrage instantané, pas de build à chaque redémarrage). Le service
`hermes-dashboard.service` (fourni) gère ça.

**Installer le service** (root) :
```bash
ssh root@$VPS '
  cp /root/hermes-dashboard.service /etc/systemd/system/hermes-dashboard.service
  systemctl daemon-reload
  systemctl enable --now hermes-dashboard
  systemctl status hermes-dashboard --no-pager | head
'
```

> **Bind `0.0.0.0` sans `--insecure`** : dès que les credentials basic-auth sont dans `.env`,
> l'auth gate s'active et le bind non-loopback est autorisé sans `--insecure`. UFW (`tailscale0`
> only) garantit que `9119` n'est joignable que via le tailnet.

**Vérifier** (depuis le Mac, via tailnet) :
```bash
curl -s http://$VPS:9119/api/status | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['auth_required'],d['auth_providers'],d['gateway_state'])"
# attendu : True ['basic'] running
curl -s -o /dev/null -w "%{http_code}\n" http://$VPS:9119/api/config   # attendu : 401
```

## 8. Connecter l'app desktop (Mac)

App Hermes desktop → **Settings → Gateway → Remote gateway** :
- **Remote URL** : `http://<VPS_TS_IP>:9119` (l'IP tailscale du VPS)
- **Sign in** : `admin` + le mot de passe noté → **Save and reconnect**

> ⚠️ La sonde « ready » de l'app ne teste que `/api/status` (public). **Le vrai test = envoyer un
> message dans l'onglet CHAT.** Si l'agent répond, le WebSocket `/api/ws` passe = OK. Sinon, voir
> *Settings → Gateway → Open logs* : close code `4401` (ticket d'auth) ou `4403` (Host/peer mismatch).

---

## 9. Ajouter Slack plus tard (reporté)

Bloqué ici par la **limite de 10 apps d'un workspace Slack gratuit**. Pour reprendre :

1. Libérer un slot (supprimer une app sur `slack.com/apps/manage`) ou utiliser un autre workspace.
2. Générer le manifest : `hermes slack manifest --write` (écrit `~/.hermes/slack-manifest.json`).
3. api.slack.com/apps → Create New App → **From an app manifest** → coller le JSON.
   (Si l'app existe déjà : **Features → App Manifest** → coller → Save.)
4. **Settings → Basic Information → App-Level Tokens** → Generate (scope `connections:write`) → `xapp-…`.
5. **Settings → Install App** → Install to Workspace → `xoxb-…`.
6. Member ID Slack : profil → ⋮ → Copy member ID (`U…`).
7. `hermes gateway setup` → cocher **Slack** → coller `xoxb-` + `xapp-` + member ID.
8. Redémarrer le gateway user : `systemctl --user restart hermes-gateway`.

Astuce : pour coller le manifest facilement → `ssh root@$VPS "cat /home/hermes/.hermes/slack-manifest.json" | pbcopy`.

---

## Maintenance

```bash
# État des services
ssh root@$VPS 'systemctl status hermes-dashboard --no-pager | head'
ssh root@$VPS "su - hermes -c 'export XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus; systemctl --user status hermes-gateway --no-pager | head'"

# Logs
ssh root@$VPS 'tail -f /home/hermes/.hermes/logs/gateway.log'    # gateway
ssh root@$VPS 'journalctl -u hermes-dashboard -f'                # dashboard

# Mise à jour Hermes (user hermes), puis redémarrage des services
su - hermes -c 'hermes update'

# Si l'update a changé le web UI du dashboard : rebuilder une fois.
# Le service tourne avec --skip-build, donc on rebuild à la main puis on redémarre.
su - hermes -c 'cd ~/.hermes/hermes-agent && hermes dashboard --no-open --host 127.0.0.1 --port 9120'
# (laisser finir le build tsc/vite ~70 s, puis Ctrl-C ; le service reprend le web_dist/ à jour)
systemctl restart hermes-dashboard   # en root

# Redémarrer le gateway (en tant que hermes, AVEC l'env du bus user) :
su - hermes -c 'export XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus; systemctl --user restart hermes-gateway'

# Changer de modèle (ex. passer à un payant après ajout de crédits)
su - hermes -c 'hermes model'

# Backup de l'état (config, OAuth Nous, token bot, credentials dashboard) — voir §Résilience
ssh root@$VPS 'tar czf - -C /home/hermes .hermes/.env .hermes/config 2>/dev/null' > "hermes-backup-$(date +%F).tar.gz"
```

## Sécurité — récapitulatif

- **Frontière réelle** : OS + réseau. UFW deny-incoming, seuls 22 et `tailscale0` ouverts.
- **Seule surface publique = SSH (22)** : ouvert sur l'IP publique comme filet anti-lockout (assumé).
  Mitigé par `fail2ban` + `hermes` sans mot de passe. Durcissable : restreindre 22 à `tailscale0`
  (`ufw delete allow OpenSSH`) et/ou couper l'auth par mot de passe `sshd`. Cf. ADR §1.
- **Pas d'exposition applicative** : dashboard et gateway joignables uniquement via le tailnet.
- **Auth** : dashboard derrière basic-auth ; Telegram deny-by-default + DM pairing.
- **`http://` sans TLS, volontaire** : le dashboard sert en clair, mais le seul chemin pour l'atteindre
  est le tunnel Tailscale (WireGuard), déjà chiffré de bout en bout. Pas de certificat à gérer ; le
  mot de passe basic-auth ne transite jamais hors du tunnel chiffré.
- **User non-privilégié** : l'agent tourne en `hermes` (pas root, pas de sudo sans mot de passe).
- **Backend terminal `local`** : acceptable pour usage solo + allowlist. Si ouverture à des tiers
  ou ingestion de contenu non fiable → envisager un backend isolé (cf. la doc sécurité du projet Hermes upstream).
- **Secret redaction** active sur le gateway (logs/réponses scrubbés).

## Résilience & limites connues

Points opérationnels à connaître pour un fonctionnement 24/7 durable :

- **Expiration de clé Tailscale** : à désactiver sur le nœud VPS (cf. §1). Sans ça, le VPS sort du
  tailnet après ~180 j et l'accès dashboard + SSH-via-tailnet est perdu (filet : 22 public + console
  Hostinger).
- **Backup / disaster recovery** : tout l'état vit dans `~/.hermes` (OAuth Nous, token bot Telegram,
  `.env` credentials dashboard). Sans sauvegarde, un VPS perdu/réinstallé = tout à refaire à la main.
  Sauvegarder régulièrement (cf. snippet en §Maintenance) et stocker hors-VPS. Ces fichiers
  contiennent des secrets → backup chiffré, jamais commité.
- **Dépendance Tailscale** : si le tailnet est indisponible (panne, compte, clé), l'accès passe par le
  22 public puis la console web Hostinger (hors-bande). C'est le filet ultime — ne pas le supprimer.
- **Modèle gratuit Nous** : `nemotron-3-ultra:free` peut être rate-limité, voire retiré côté provider.
  Bascule vers un payant en 1 commande (`hermes model`, après ajout de crédits) — cf. ADR §5.
- **Mises à jour OS** : `unattended-upgrades` est installé (sécurité auto), mais sans reboot
  automatique : un kernel mis à jour ne s'applique qu'au prochain reboot manuel.

## Fichiers de ce dépôt

| Fichier | Rôle |
|---|---|
| `01-vps-prep.sh` | Prep OS (root) : maj, user hermes, UFW, Tailscale |
| `02-hermes-user-setup.sh` | Install Hermes (user hermes) |
| `hermes-dashboard.service` | Service systemd system du dashboard |
| `docs/decisions/0001-*.md` | ADR : décisions d'architecture et justifications |
