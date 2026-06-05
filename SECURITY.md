# Politique de sécurité

Ce document décrit le **modèle de sécurité du déploiement** documenté dans ce dépôt
(runbook + scripts + ADR). Il ne couvre pas le code de Hermes Agent lui-même : pour les
vulnérabilités du produit, voir la doc sécurité du projet **Hermes (upstream)**.

## Portée

Ce dépôt contient **de la documentation et des scripts de déploiement**, pas de secret ni
de service en production. Sont concernés ici :

- les scripts `01-vps-prep.sh`, `02-hermes-user-setup.sh` et l'unit `hermes-dashboard.service` ;
- les choix d'architecture sécurité décrits dans `docs/decisions/0001-*.md` et `README.md`.

**Hors périmètre** : le code de Hermes Agent, l'API Nous Portal, Tailscale, Telegram/Slack.

## Modèle de menace

Le déploiement vise un **usage solo, sur un VPS dédié**, piloté via un tailnet privé.

- **Ce qu'on protège** : l'accès au VPS, au dashboard et à l'agent ; les secrets locaux
  (OAuth Nous, token bot Telegram, credentials dashboard) dans `~/.hermes`.
- **Contre quoi** : exposition publique d'internet (scan/brute-force), accès non autorisé au
  bot de messagerie, exécution de commandes via injection de prompt.
- **Attaquant non considéré** : un acteur ayant déjà un accès root au VPS, ou le contrôle du
  compte Tailscale/Nous/Telegram (hors périmètre — relève de l'hygiène de ces comptes).

## Frontières & mitigations

Détail et justification dans l'ADR `docs/decisions/0001-*.md` ; récapitulatif dans
`README.md` §Sécurité. En résumé :

- **Réseau** : UFW deny-incoming ; seuls le SSH (22) et l'interface `tailscale0` sont ouverts.
  Dashboard (`9119`) et gateway ne sont joignables que via le tailnet privé (WireGuard chiffré).
- **Seule surface publique = SSH (22)**, gardé comme filet anti-lockout. Mitigé par `fail2ban`
  et le user applicatif `hermes` en `--disabled-password`. Durcissable (cf. ci-dessous).
- **Auth dashboard** : basic-auth obligatoire ; le bind non-loopback n'est autorisé que parce que
  l'auth gate est active. Pas de TLS car le seul chemin d'accès est déjà chiffré par Tailscale.
- **Messagerie** : Telegram en **deny-by-default** (allowlist) + pairing par DM ; le bot n'est pas
  public.
- **Privilèges** : l'agent tourne en user non-root `hermes`, sans `sudo` (gateway en service
  systemd *user* + linger).
- **Secrets** : `secret redaction` active sur le gateway ; `~/.hermes/.env` en `chmod 600`.

## Backend d'exécution (risque principal)

L'agent exécute des commandes shell via le backend `terminal` en mode **`local`**. Une
**injection de prompt** (via un message entrant) pourrait donc faire exécuter une commande
avec les droits de `hermes`.

Mitigations en place : user non-root, allowlist Telegram stricte, approbations `manual`,
secret redaction, VPS dédié.

➜ **À reconsidérer impérativement** si le bot est ouvert à des tiers ou ingère du contenu non
fiable (web, fichiers externes) : passer à un **backend isolé** (conteneur/sandbox). Détails
côté projet Hermes (upstream).

## Durcissement recommandé pour qui réutilise ce runbook

- **Désactiver l'expiration de clé** du nœud VPS dans Tailscale (sinon perte d'accès ~180 j —
  cf. README §1).
- **Restreindre le SSH au tailnet** une fois Tailscale SSH validé : `ufw delete allow OpenSSH`
  (le 22 n'est alors plus public), en gardant la console hors-bande de l'hébergeur comme filet.
- **Couper l'auth par mot de passe** côté `sshd` (`PasswordAuthentication no`).
- **Sauvegarder `~/.hermes`** hors du VPS, **chiffré** : il contient des secrets. Ne jamais le
  committer (cf. README §Résilience & §Maintenance).
- **Ne jamais committer** `.env*`, tokens, clés : voir `.gitignore`.

## Signaler une vulnérabilité

Pour un problème de sécurité **dans les scripts ou la documentation de ce dépôt** :

1. Ouvrir un **avis de sécurité privé** via l'onglet **Security → Report a vulnerability** du
   dépôt GitHub (divulgation responsable, non publique).
2. À défaut, ouvrir une issue **sans détailler l'exploit** et demander un canal privé.

Merci de **ne pas divulguer publiquement** avant correction. Ce dépôt étant de la documentation,
il n'y a pas de versions « supportées » : seul l'état de la branche `main` fait foi.
