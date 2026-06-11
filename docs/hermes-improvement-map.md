# Cartographie d'amélioration — Hermès Agent (VPS)

> Veille + backlog priorisé. Date : 2026-06-11. Instance VPS : Hermes **v0.16.0** (`v2026.6.5` "Surface", 2026-06-06) — **à jour**.
> Méthode : lecture directe du repo `NousResearch/hermes-agent` (via `gh`), doc officielle `hermes-agent.nousresearch.com`, CLI `hermes`, veille web 2026. Légende : **[V]** vérifié source primaire · **[T]** sourcé tiers daté · **[S]** supposé/à valider.

---

## 0. TL;DR

- **Version** : à jour, rien à rattraper. Cadence upstream ~hebdo, < v1.0 → breaking changes fréquents, suivre les release notes.
- **Posture actuelle** : provider Nous Portal (`nemotron-3-ultra:free`), channel Telegram, 2 crons, backend `local`, **0 MCP, 0 mémoire longue, 0 multi-agent, 0 sandbox**.
- **3 angles morts majeurs** : (1) aucun outil de recherche/scraping branché en MCP sur un agent *de veille* ; (2) aucune mémoire cumulative → agent amnésique ; (3) sécurité — backend `local` + Telegram non fiable = config hors périmètre supporté upstream.
- **Lock-in Nous Portal = faux problème** : Hermes supporte ~35 providers LLM, switch à chaud. Le vrai sujet n'est pas "comment sortir de Portal" mais "fiabiliser le canal modèle" (le `:free` est fragile, pas le modèle).

> ⚠️ **À vérifier en SSH avant d'agir** : `layout.md` indique `nvidia/nemotron-3-ultra:free` sur le VPS ; l'instance locale Mac auditée tournait `stepfun/step-3.7-flash:free`. Confirmer la config réelle du VPS (`hermes config get model`, `hermes mcp list`, `hermes memory status`, `approvals.cron_mode`, skills installés) — la présente carte raisonne sur l'état déclaré, pas mesuré.

---

## 1. Roadmap & état upstream

**Repo** : `github.com/NousResearch/hermes-agent` (MIT, ~190k★, très actif, versioning calendaire `vYYYY.M.D` + semver `v0.x`). **[V]**

- **Pas de roadmap officielle** : ni page roadmap, ni milestones, ni labels `planned`. Le futur = release notes (passé) + issues/RFC communautaires (non engageantes) + annonces X. **[V]**
- **Direction produit assumée** : **Hermes Desktop** (app Electron, public preview, démo keynote GTC) — montée en charge GUI attendue. Débat interne ouvert (#41180 `needs-decision`) sur le risque de glissement "power-user harness → GUI grand public". **[V]**
- **Tendances de fond dans les issues** (non mergées) : mémoire tiered multi-couche (#32726, #25456, #28279), multi-user gateway access control (#20744), vérification d'éditeur pour skills (#40555), nouveaux providers (ByteDance ModelArk #40195). **[V]**
- **Spéculatif** (presse tierce, non Nous) : v1.0 mi/fin-2026, per-tenant memory isolation, audit logging, API stability guarantees. **[T]**

**Nouveautés v0.15→v0.16 exploitables chez nous** (probablement non activées) :
1. **Panel admin web complet** — configurer MCP/channels/webhooks/credentials/memory depuis le navigateur, fini l'édition SSH de `config.yaml`. **[V]**
2. **Kanban multi-agent / swarm + worktree-per-task + cron de tâches** — orchestration de sous-agents. **[V]**
3. **Bitwarden Secrets Manager** — un token bootstrap remplace les N secrets en clair de `~/.hermes/.env`. **[V]**
4. **Auth OIDC self-hosted / user-password pluggable** — remplace le basic-auth `admin` du dashboard. **[V]**
5. **`/undo [N]` + session search 4500× plus rapide (gratuite)**. **[V]**

**Breaking changes à anticiper au prochain `hermes update`** :
- Build web UI déjà cassé par un retrait de props `@nous-research/ui` (#39893). **[V]**
- Bouquet d'issues P2 sur stop/restart du gateway sous systemd (#41631, #24344, #43475) → un `systemctl stop` "propre" peut remonter `failed` + boucle `Restart=always`. **À auditer sur notre unit.** **[V]**
- Skills par défaut retirés/déplacés (v0.16) → re-`hermes skills install` si un cron en dépendait. **[V]**
- Modèles xAI retirés (15 mai) ; détection auto + `hermes migrate xai`. Vérifier que nos crons ne pointent pas un modèle sunset. **[V]**

---

## 2. Providers branchables (tous types)

### 2.1 LLM — ~35 providers, switch à chaud (`hermes model`), « no lock-in » **[V]**
- Cloud API : `nous`, `openrouter`, `openai-api`, `anthropic` (clé ou OAuth Claude Max), `gemini`, `xai`, `deepseek`, `nvidia`, `zai` (GLM), `kimi`, `qwen`, `minimax`, `stepfun`, etc.
- Enterprise : `bedrock`, `azure-foundry`. Local : `lmstudio`, `ollama-cloud`, et **`custom`** (tout endpoint OpenAI-compatible : Ollama/vLLM/SGLang/llama.cpp).
- **Local exige** : contexte ≥ 64k + flags tool-calling (`--enable-auto-tool-choice` vLLM, `--tool-call-parser` SGLang). **Non réaliste sur notre VPS sans GPU** — l'inférence reste distante.
- **Résilience native** : `hermes fallback add` (chaîne de repli sur rate-limit/overload), `credential_pool_strategies` (round_robin/least_used), **auxiliary models** séparés (vision/web_extract/compression sur un modèle cheap pour ne pas brûler le quota principal).

### 2.2 Mémoire — 9 providers, **un seul actif**, pipeline auto (préfetch/sync/extraction) **[V]**
`honcho`, `openviking`, `mem0`, `hindsight` (knowledge graph, **local gratuit**), `holographic` (SQLite local), `retaindb`, `byterover`, `supermemory`, `memori`.
- **Pas de provider Graphiti/Zep natif**, et l'interface `MemoryProvider` formelle a été refusée (#3943 closed/not planned). → Pour le backlog AGEA/Graphiti, le chemin réel est **MCP plugin**, pas un memory-provider natif.
- État de l'art temporel : Graphiti/Zep (LongMemEval 63.8 % vs Mem0 49 %) — pertinent seulement si la dimension "fait vrai au T1, supersédé au T2" devient centrale. **[T]**

### 2.3 Tools / MCP — support client **et** serveur, complet **[V]**
- `hermes mcp add/install/serve` ; catalogue Nous-approved minuscule (`linear`, `n8n`) → reste en config manuelle `mcp_servers:`.
- **Tool Search / progressive disclosure** (`auto`) : retire les schémas MCP du contexte au-delà de ~10 % de fenêtre → à activer dès qu'on empile des MCP.
- Pitfall VPS headless : OAuth MCP → callback loopback ne joint pas le laptop → paste-back ou `ssh -L`.
- **MCP recommandés veille/portfolio** [T] : **Exa** (recherche sémantique), **Firecrawl** (scraping→markdown), **CoinGecko MCP officiel** (remote hosté, zéro install), `server-github` read-only pour suivre les releases.

### 2.4 Channels — ~23 plateformes (gateway unique) **[V]**
Telegram (actif), Discord, Slack, WhatsApp, Signal, Email, Teams, Matrix, ntfy, etc. Helpers `hermes slack`/`hermes whatsapp`.

---

## 3. Modèle LLM — diagnostic & reco

- **Le modèle n'est pas le problème, le canal l'est.** Nemotron 3 Ultra (MoE 550B, hybride Mamba-Transformer, 1M ctx, conçu pour l'agentic long-running) est bon. Mais l'endpoint **`:free`** = 20 req/min, 200 req/jour, *retrait possible sans préavis* → **inadapté à de la prod**. **[V]**
- La doc Hermes **déconseille les modèles Hermes 4** dans la boucle agentic (chat/reasoning, pas tool-call-tuned). Contre-intuitif mais documenté. **[V]**
- Défauts recommandés par Hermes pour l'agent : `claude-sonnet-4.6`, `gpt-5.4`, `gemini-2.5-pro`, `deepseek-v3.2`. **[V]**

| Modèle | Profil agentic | Coût (in/out /M) | Note |
|---|---|---|---|
| **DeepSeek V3.2** | recommandé Hermes, fiable | ~$0.23 / $0.34 | **meilleur fallback payant** |
| GLM-4.7-Flash | bon agentic open | **gratuit** | secours $0 |
| Nemotron 3 Ultra (actuel) | fort, long-running | $0 en `:free` | bon modèle, **canal fragile** |
| Claude Sonnet 4.6 | défaut Hermes | payant Portal | référence qualité |

**Reco** : Nemotron via **Nous Portal** (Free/Plus, pas l'endpoint `:free` OpenRouter) + **DeepSeek V3.2 en `fallback` câblé** sur 429. Quasi nul en coût pour de la veille légère, élimine le risque de coupure.

---

## 4. Angles morts opérationnels & sécurité

- **Sécurité (le plus sérieux)** : `SECURITY.md` upstream déclare *« the only security boundary against an adversarial LLM is the operating system »* et place **explicitement hors périmètre** notre config (backend `local` + input non maîtrisée). Telegram entrant + web récupéré = surface d'injection indirecte. **Lethal trifecta** = input non fiable + accès sensible + capacité d'agir/exfiltrer → notre agent les cumule potentiellement. **[V/T]**
  - Parades : `terminal.backend: docker` (confine shell/file-tools), whitelist Telegram stricte, egress filtering (UFW sortant + DNS), human-in-the-loop sur effets de bord, `approvals.cron_mode` (défaut `deny` — **à vérifier qu'on n'est pas en YOLO**).
- **Update** : `hermes update` est riche (snapshot pairing, validation + rollback `git reset --hard` auto, restart gateway, survit à SIGHUP). Flags : `--check` (dry-run pour cron), `--backup` (prod). **Best-practice : pinner un tag de release plutôt que suivre `main`.** **[V/T]**
- **Observabilité** : pas d'OTel natif. Dispo : observer hooks + plugin **Langfuse** opt-in (traces/coût), health endpoint `/health/detailed` (sous `API_SERVER_ENABLED=true`) scrapable par Uptime Kuma/healthchecks.io. Cron : `hermes cron list --all` montre `⚠ Delivery failed` (run OK mais livraison Telegram KO). **[V]**
- **Fiabilité** : **watchdog systemd** (`Restart=on-watchdog` + `WatchdogSec`) détecte le *freeze*, pas juste le crash. Backup `~/.hermes` hors VPS (config/auth/sessions/skills/mémoire = tout l'état "self-improving"). **[V/T]**
- **Coût VPS** : Hostinger facturé en continu, "sommeil" ne réduit rien. L'agent est I/O/réseau (inférence distante) → **KVM4 probablement surdimensionné**, descendre de tier après audit conso idle. Surveiller le **prix de renouvellement** (+140 à +232 % selon plan). **[T/S]**

---

## 5. Backlog priorisé

Score : Impact (1-5) · Effort (F/M/É) · Risque si on ne fait rien.

| # | Action | Impact | Effort | Pourquoi | Réf |
|---|---|---|---|---|---|
| **B1** | **Fallback modèle** Nemotron(Portal) → DeepSeek V3.2 sur 429 | 5 | F | Sort du risque 200 req/j + retrait sans préavis du `:free`. Quick win résilience. | §3 |
| **B2** | **Brancher MCP veille** : Exa + Firecrawl | 5 | F | Cœur manquant d'un agent *de veille* : recherche sémantique + scraping. | §2.3 |
| **B3** | **Activer mémoire longue native** (`hindsight` local) | 5 | F | Agent amnésique → cumulatif. Gratuit, sur le VPS, pipeline auto. | §2.2 |
| **B4** | **CoinGecko MCP** pour les crons portfolio | 4 | F | Données prix live dans `portfolio-refresh`. Remote, zéro install. | §2.3 |
| **B5** | **Casser la lethal trifecta** : whitelist Telegram + egress filtering + audit `cron_mode` | 5 | M | Risque d'injection sur VPS prod 24/7. Le plus important au plan sécurité. | §4 |
| **B6** | **Durcir l'exécution** : `terminal.backend: docker` | 4 | M | Notre config est hors périmètre supporté upstream. Confine shell/file. | §4 |
| **B7** | **Watchdog systemd + cron `hermes update --check`** → alerte Telegram | 4 | F | Détecte freeze du polling + dispo d'update sans pull auto. | §4 |
| **B8** | **Backup `~/.hermes` hors VPS + snapshot avant update + pinner un tag** | 4 | F | Protège l'état self-improving ; évite de suivre `main` cassable. | §1,§4 |
| **B9** | **Ouvrir le Skills Hub** : `finance/*`, `research/{arxiv,blogwatcher,polymarket}` | 3 | F | Capacités métier prêtes, alignées veille/portfolio. Scan/quarantine en place. | §1 |
| **B10** | **Bitwarden Secrets Manager** (un token bootstrap) | 3 | M | Supprime les secrets en clair de `.env`. Aligné posture sécurité. | §1 |
| **B11** | **Délégation** : relever `delegation.max_spawn_depth`/`max_concurrent_children` | 3 | M | Fan-out one-shot pour briefs de veille multi-sujets. Pas le Kanban (surdimensionné). | §1 |
| **B12** | **Langfuse opt-in + health endpoint** scrapable | 3 | M | Tracing coût/latence/anomalies d'un agent 24/7. | §4 |
| **B13** | **Audit conso + right-size VPS** (descendre de tier) | 2 | F | KVM4 probablement surdimensionné pour de l'I/O. | §4 |

**Ordre d'attaque** : vague 1 (résilience + capacité, tous F) = B1+B2+B3+B4+B7+B8 → vague 2 (sécurité) = B5+B6 → vague 3 (selon appétence) = B9–B13.

---

## 6. Lien avec la décision projet

Le projet est en sommeil (décision "reprendre / arrêter / détruire VPS" en suspens). Cette carte éclaire :
- **Si reprise** : la vague 1 transforme l'agent de "démo amnésique sans outils" en "agent de veille réel" pour un effort faible (1 session). C'est ce qui justifierait la reprise.
- **Si arrêt** : B8 (backup hors VPS) reste le minimum à faire avant `disable`/destroy.
- **Coût** : B13 réduit la facture si on garde le VPS endormi en attendant.

---

## Sources principales
- Repo & releases : `github.com/NousResearch/hermes-agent/releases` (`v2026.6.5`, `v2026.5.28`)
- Doc : `hermes-agent.nousresearch.com/docs/{integrations/providers, getting-started/updating, user-guide/features/{memory-providers,fallback-providers}, user-guide/messaging}`
- Issues : #41180, #20744, #40555, #32726, #39893, #41631, #3943
- Modèles : OpenRouter (Nemotron 3 Ultra `:free`), NVIDIA tech report, whatllm agentic 2026, pricepertoken (DeepSeek)
- Sécurité/ops : Unit42 & Airia (prompt injection / lethal trifecta), oneuptime (systemd watchdog), Hostinger pricing 2026
