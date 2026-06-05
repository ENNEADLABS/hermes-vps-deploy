# 0001 — Déploiement Hermes Agent sur VPS Hostinger (accès, services, modèle, sécurité)

- Statut : **accepté**
- Date : 2026-06-05
- Contexte projet : faire tourner Hermes Agent 24/7 sur un VPS Hostinger KVM4 (Ubuntu 24.04),
  piloté depuis l'app desktop macOS et depuis Telegram.

Ce document regroupe les décisions structurantes prises pendant le déploiement. Le « comment »
reproductible est dans `../../README.md`.

---

## 1. Accès distant : Tailscale SSH plutôt que port ouvert ou reverse proxy

### Contexte
Il faut accéder au VPS en SSH et exposer le backend dashboard à l'app desktop, sans transformer
le VPS en cible publique. L'accès initial se faisait via la console web Hostinger (hors-bande).

### Options considérées
- **A. Port SSH 22 ouvert sur internet + dashboard derrière reverse proxy + domaine + TLS.**
  Surface publique, gestion certificats, fail2ban indispensable, exposition des API keys si le
  proxy faiblit.
- **B. Tunnel SSH manuel** pour chaque accès au dashboard. Pas d'exposition, mais friction à
  chaque session, pas adapté à une app desktop qui se connecte en continu.
- **C. Tailscale (mesh VPN privé) + Tailscale SSH.** Aucun port public, SSH sans mot de passe ni
  clé gérée, accès identique pour SSH/dashboard/app desktop.

### Décision
**Option C.** `tailscale up --ssh` sur le VPS ; le Mac et le VPS sur le même tailnet. UFW
n'autorise que `22` et l'interface `tailscale0`. Le dashboard bind `0.0.0.0` mais n'est joignable
que via le tailnet.

### Conséquences
- (+) Zéro port applicatif exposé sur internet ; auth réseau gérée par Tailscale.
- (+) SSH/scp depuis le Mac sans clé à gérer ; l'app desktop atteint le backend par IP tailscale.
- (−) Dépendance à Tailscale (coordination, compte). Mitigé : la console web Hostinger reste un
  accès hors-bande de secours.
- (−) **Le port 22 reste ouvert sur l'IP publique** : `ufw allow OpenSSH` ouvre 22/tcp sur *toutes*
  les interfaces (pas seulement `tailscale0`). C'est volontaire — filet anti-lockout si `tailscaled`
  tombe et que la console Hostinger est indisponible — mais c'est la **seule surface publique**
  restante. Mitigée par `fail2ban` (installé) et `hermes` en `--disabled-password`. Durcissement
  possible si besoin : restreindre 22 au tailnet (`ufw delete allow OpenSSH`, le SSH passant alors
  uniquement par `tailscale0`) et/ou couper l'auth par mot de passe côté `sshd`. **Non fait** : on
  garde une porte de secours hors-tailnet assumée.

---

## 2. Anti-lockout UFW : autoriser `tailscale0` avant d'activer le pare-feu

### Contexte
Activer UFW (deny incoming par défaut) alors qu'on est connecté via Tailscale SSH risque de
couper sa propre session.

### Décision
Dans `01-vps-prep.sh`, exécuter `ufw allow in on tailscale0` **avant** `ufw --force enable`
(en plus de `ufw allow OpenSSH`).

### Conséquences
- (+) Aucun risque de lockout ; tout le trafic du tailnet privé passe (dont SSH et `9119`).
- (+) Pas besoin de règle UFW dédiée par port pour les services exposés au tailnet.
- (−) Tout `tailscale0` est ouvert (pas de moindre-privilège par port). Acceptable : tailnet privé
  à 2 appareils. La console web reste le filet ultime.

---

## 3. Gateway en service systemd USER + linger (pas system service)

### Contexte
Le gateway doit tourner 24/7 et démarrer au boot. Le user `hermes` a été créé **sans mot de passe**
(`--disabled-password`) → pas de `sudo`. `hermes gateway install` a échoué en service system, et
`systemctl --user` échoue dans une session `su` (« Failed to connect to bus: No medium found »).

### Options considérées
- **A. Service system** (`/etc/systemd/system`), `User=hermes`. Nécessite `sudo` → donner un
  mot de passe ou `NOPASSWD` à `hermes` = élargir la surface root de l'agent (risqué, l'agent est
  exposé au messaging).
- **B. Service user** (`systemctl --user`) + `loginctl enable-linger hermes` pour qu'il tourne
  sans session ouverte.

### Décision
**Option B.** Service user + linger. Les commandes `systemctl --user` se lancent en root via
`su - hermes` en exportant `XDG_RUNTIME_DIR=/run/user/1001` et `DBUS_SESSION_BUS_ADDRESS`.

### Conséquences
- (+) L'agent n'a aucun privilège root (meilleure posture de sécurité).
- (+) Survit déconnexion + reboot grâce au linger.
- (−) Manipulation moins intuitive (`systemctl --user` nécessite l'env du bus) — documenté dans
  le README §6 et §Maintenance.

---

## 4. Dashboard : bind `0.0.0.0` + basic-auth + UFW tailscale, sans `--insecure`

### Contexte
L'app desktop se connecte au dashboard distant. Un bind loopback (`127.0.0.1`) rejette les clients
distants au niveau socket. Le flag `--insecure` existe pour forcer un bind non-loopback.

### Options considérées
- **A. Loopback + tunnel SSH** vers `9119`. Pas adapté à une app desktop persistante.
- **B. `--insecure` + `0.0.0.0`.** Force le bind mais nom alarmant ; pensé pour bypass d'auth.
- **C. `0.0.0.0` avec credentials basic-auth dans `.env`.** L'auth gate s'active automatiquement
  sur bind non-loopback → le bind est autorisé **sans** `--insecure`. UFW restreint `9119` au
  tailnet ; basic-auth protège les endpoints sensibles (`/api/config` → 401).

### Décision
**Option C.** Service system `hermes-dashboard.service`, `--host 0.0.0.0 --port 9119 --skip-build`,
credentials basic-auth dans `~/.hermes/.env`, web UI pré-buildé une fois.

### Conséquences
- (+) App desktop connectée via tailnet ; double protection (réseau tailnet + basic-auth).
- (+) `--skip-build` → démarrage instantané (le build tsc/vite ~70 s n'a lieu qu'une fois).
- (−) Après un `hermes update` qui change le web UI, il faut rebuilder (relancer une fois sans
  `--skip-build`). Documenté en Maintenance.
- (−) Dashboard en service **system** (alors que le gateway est user) — léger écart de modèle,
  justifié car son installation/contrôle se fait en root et il n'a pas le souci du bus user.

---

## 5. Modèle : Nous Portal en modèle gratuit (`nemotron-3-ultra:free`)

### Contexte
Le compte Nous Portal est authentifié mais **sans crédits** → les modèles payants renvoient
`requires available credits`.

### Options considérées
- **A. Ajouter des crédits** pour un modèle payant économique (quelques centimes de $ par Mtok).
- **B. Modèle gratuit** `nvidia/nemotron-3-ultra:free` (le plus capable des gratuits).

### Décision
**Option B** pour démarrer sans coût et valider tout le pipeline. Bascule vers un payant possible
en 1 commande (`hermes model`) après ajout de crédits.

### Conséquences
- (+) Zéro coût récurrent ; pipeline complet validé.
- (−) Le tier gratuit peut imposer des limites de débit gênantes pour un usage 24/7 intensif →
  réévaluer si le bot devient sollicité.

---

## 6. Backend terminal `local` (pas d'isolation conteneur pour l'instant)

### Contexte
L'agent exécute des commandes shell via le backend `terminal`. Il est exposé au messaging
(Telegram), surface d'ingestion potentiellement non fiable.

### Décision
Garder le backend **`local`** : usage solo + allowlist Telegram (deny-by-default + DM pairing),
sur un VPS dédié. Docker a d'ailleurs été désinstallé (vestige n8n) pour réduire la surface.

### Conséquences
- (+) Simplicité, performance, pas de couche conteneur.
- (−) Une commande malveillante (via injection de prompt) s'exécuterait avec les droits de `hermes`.
  Mitigé : user non-root, allowlist stricte, approbations `manual`, secret redaction. **À
  reconsidérer** (backend Docker/Modal) si le bot est ouvert à des tiers ou ingère du web non fiable
  — voir la doc sécurité du projet Hermes (upstream) sur les backends isolés.

---

## Décisions reportées

- **Slack** : non déployé (limite 10 apps du workspace gratuit). Procédure prête (README §9),
  config côté Hermes à faire au moment de l'ajout — aucune dette technique en attendant.
