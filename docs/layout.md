# Layout — Carte opérationnelle du déploiement Hermes VPS

> Référence rapide de l'état réel du setup. Pour la procédure reproductible → `README.md`. Pour les décisions et leur justification → `docs/decisions/`.
>
> Ce fichier est un **template public** avec placeholders. Les vraies valeurs sont dans `docs/layout.local.md` (gitignored, local uniquement).

---

## Infrastructure

| Composant | Valeur |
|---|---|
| VPS | Hostinger KVM4, Ubuntu 24.04 LTS |
| IP tailscale | `<VPS_TS_IP>` |
| IP publique | (voir panel Hostinger — jamais utilisée en accès direct) |
| User applicatif | `hermes` (UID 1001, sans mot de passe) |
| Runtime bus user | `/run/user/1001/` (activé via `loginctl enable-linger hermes`) |

## Réseau

- **UFW** : deny incoming par défaut ; `ufw allow OpenSSH` (22/tcp, toutes interfaces — filet anti-lockout) + `ufw allow in on tailscale0`
- **Seule surface publique** : port 22/tcp
- Dashboard (9119) et gateway non joignables depuis internet — tailnet uniquement

## Services actifs

| Service | Type systemd | Commande de contrôle |
|---|---|---|
| `hermes-dashboard` | system | `systemctl status hermes-dashboard` |
| `hermes-gateway` | user + linger | voir ci-dessous |

```bash
# Contrôle du gateway (depuis root, avec env bus user) :
su - hermes -c 'export XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus; \
  systemctl --user status hermes-gateway --no-pager | head'
```

## Accès

| Canal | Adresse | Auth |
|---|---|---|
| SSH (Mac) | `ssh root@<VPS_TS_IP>` | Tailscale SSH (sans clé) |
| Dashboard | `http://<VPS_TS_IP>:9119` | basic-auth (`admin` / voir `.env`) |
| App desktop | Remote gateway → `http://<VPS_TS_IP>:9119` | basic-auth |
| Telegram | bot @… | deny-by-default + DM pairing |

> Expiration de clé tailscale : désactivée sur le nœud VPS (`Disable key expiry` dans la console admin Tailscale). À revérifier si le tailnet perd le VPS.

## Modèle LLM

- Provider : Nous Portal (OAuth)
- Modèle actif : `nvidia/nemotron-3-ultra:free`
- Bascule vers payant : `su - hermes; hermes model` (après crédits sur portal.nousresearch.com)

## Crons actifs (profil `default`)

| Nom | Schedule | Deliver |
|---|---|---|
| `portfolio-refresh` | `0 7 * * *` — quotidien 7h UTC | Telegram |
| `vault-watch` | `0 8 * * 1` — lundi 8h UTC | Telegram |

```bash
# Vérification en direct :
ssh root@<VPS_TS_IP> 'su - hermes -c "hermes cron status && hermes cron list"'
```

Scripts dans `/home/hermes/portfolio-analysis/` sur le VPS.

## Chemins clés (VPS, user hermes)

| Chemin | Contenu |
|---|---|
| `~/.hermes/` | Tout l'état Hermes (OAuth Nous, token bot, config) |
| `~/.hermes/.env` | Credentials dashboard basic-auth, secrets bot Telegram |
| `~/.hermes/config` | Configuration agent (provider, modèle, gateway channels) |
| `~/.hermes/logs/gateway.log` | Logs gateway Telegram (vérifier `✓ telegram connected`) |
| `~/portfolio-analysis/` | Scripts de monitoring portfolio + analyses |

## Repos

| Repo | Local (Mac) | Remote |
|---|---|---|
| `hermes-vps-deploy` | `~/hermes-vps-deploy/` | `ENNEADLABS/hermes-vps-deploy` |
| `portfolio-analysis` | `~/Dev/portfolio-analysis/` | `ENNEADLABS/portfolio-analysis` (privé) |

## Backup rapide

```bash
# Depuis le Mac — sauvegarde de l'état Hermes (secrets inclus → stocker hors-VPS, chiffré)
ssh root@<VPS_TS_IP> 'tar czf - -C /home/hermes .hermes/.env .hermes/config 2>/dev/null' \
  > "hermes-backup-$(date +%F).tar.gz"
```

## Fichiers de ce repo

| Fichier | Rôle |
|---|---|
| `01-vps-prep.sh` | Prep OS (root) : maj, user hermes, UFW, Tailscale |
| `02-hermes-user-setup.sh` | Install Hermes (user hermes) |
| `hermes-dashboard.service` | Service systemd system du dashboard |
| `docs/decisions/0001-*.md` | ADR : décisions d'architecture et justifications |
| `docs/layout.md` | Ce fichier — template public |
| `docs/layout.local.md` | Carte avec vraies valeurs (gitignored) |
| `SECURITY.md` | Modèle de menace + signalement de vulnérabilité |
| `LICENSE` | MIT |
