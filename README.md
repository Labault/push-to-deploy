# proxy-global

Infrastructure « tout-en-un » qui sert et déploie l'ensemble des applications d'un
même VPS : **reverse-proxy TLS partagé (Caddy)** + **déploiement continu par webhook**
+ **tooling d'exploitation** (sauvegardes chiffrées, monitoring uptime, diagnostic
d'incident assisté par IA). Un seul petit dépôt pilote tout le serveur.

> Pensé pour un VPS mono-serveur hébergeant plusieurs apps hétérogènes (Symfony/FrankenPHP,
> Astro, Node, WordPress, sites statiques) derrière un proxy unique, avec un déploiement
> identique quelle que soit la stack.

---

## Vue d'ensemble

```
                    Internet
                       │ 80/443 (TLS auto Let's Encrypt)
                       ▼
        ┌──────────────────────────────┐
        │   Caddy (proxy_caddy)         │  reverse-proxy + HTTPS + en-têtes sécurité
        │   *.exemple.dev, exemple.dev  │
        └───────┬───────────────┬───────┘
                │ réseau docker  │
                │    « web »     │
     ┌──────────┴───┐      ┌─────┴───────────────────────────┐
     │  apps         │      │  deploy.exemple.dev             │
     │  (conteneurs) │      │     ▼                           │
     │  Symfony,     │      │  webhook (proxy_webhook)        │ ← listener CD
     │  Astro, WP… │      │     ▼ dispatch.sh               │
     └───────────────┘      │  git pull + ./deploy.sh         │
                            └─────────────────────────────────┘

Déploiement continu :  git push main ──▶ webhook GitHub (HMAC) ──▶ dispatch.sh
                       ──▶ git reset --hard origin/main ──▶ ./deploy.sh (build + up + healthcheck)
```

Trois briques :

| Brique | Rôle | Où |
|---|---|---|
| **Reverse-proxy** | TLS auto, routage `*.domaine`, en-têtes de sécurité | [`Caddyfile`](Caddyfile), [`docker-compose.yml`](docker-compose.yml) |
| **Déploiement continu** | `push main` → build + redéploiement de l'app concernée | [`deploy/`](deploy/) ([README](deploy/README.md)) |
| **Exploitation** | sauvegardes chiffrées + monitoring + diagnostic IA | [`ops/`](ops/) ([README](ops/README.md)) |

---

## Le déploiement en une phrase

**Tu pushes sur `main`, l'app se redéploie toute seule sur le VPS** — quelle que soit
sa techno. Chaque projet embarque un script `deploy.sh` (contrat identique partout :
build → migrations éventuelles → `up` → **healthcheck HTTP bloquant**) ; le webhook
central le déclenche après avoir aligné le code sur `origin/main`.

Détails complets et procédure d'onboarding d'un nouveau projet : **[`deploy/README.md`](deploy/README.md)**.

---

## Modèle de sécurité

- **TLS** automatique (Let's Encrypt) + en-têtes de sécurité uniformes (HSTS, nosniff,
  anti-clickjacking…) via le snippet `(security_headers)` du `Caddyfile`.
- **Bases de données** : jamais exposées publiquement (réseaux docker `internal` privés
  par app).
- **Webhook signé** : seul un `POST` avec une signature HMAC-SHA256 valide (`WEBHOOK_SECRET`)
  **et** un `ref == refs/heads/main` déclenche un déploiement.
- ⚠️ Le conteneur `webhook` monte le **socket Docker** : il a donc des droits **root** sur
  l'hôte (nécessaire pour piloter les stacks). C'est le composant le plus sensible — il est
  protégé par le secret HMAC. Durcissement recommandé : clé de déploiement **lecture seule**
  via un **compte machine GitHub** dédié, *socket-proxy* Docker, allowlist des IP GitHub.
- **Secrets hors-git** : `.env` (secret HMAC, email) et la clé privée ne sont **jamais**
  committés (`.gitignore`). Les `.env` de prod sont en `chmod 600`.

---

## Démarrage rapide (setup VPS)

```bash
# 1. Réseau partagé (une seule fois)
docker network create web

# 2. Cloner et configurer
git clone git@github.com:<owner>/proxy-global.git ~/proxy-global
cd ~/proxy-global
cp .env.exemple .env          # éditer : LETSENCRYPT_EMAIL, WEBHOOK_SECRET, DEPLOYER_SSH_KEY

# 3. Démarrer le proxy + le listener de déploiement
docker compose up -d

# 4. (optionnel) installer la tooling d'exploitation -> voir ops/README.md
```

Pour brancher un projet sur le déploiement auto : **[`deploy/README.md`](deploy/README.md)**.

---

## Structure du dépôt

```
proxy-global/
├── Caddyfile              # routage + TLS + en-têtes de sécurité (un bloc par site)
├── docker-compose.yml     # services caddy + webhook, réseau « web », volumes
├── .env(.exemple)         # LETSENCRYPT_EMAIL, WEBHOOK_SECRET, DEPLOYER_SSH_KEY (hors-git)
├── deploy/                # déploiement continu
│   ├── dispatch.sh        #   résout repo→dossier, git reset --hard, lance ./deploy.sh
│   ├── projects.conf      #   table de routage  owner/repo = /srv/<dossier>
│   ├── hooks.json         #   règles du listener (HMAC + ref==main)
│   ├── deploy.sh.template #   contrat de déploiement de référence (à copier par projet)
│   └── webhook/           #   image du listener (adnanh/webhook + docker CLI + git)
└── ops/                   # exploitation (cron) — voir ops/README.md
    ├── backup.sh          #   sauvegarde chiffrée restic (bases + données + tooling)
    ├── uptime-check.sh    #   monitoring HTTP -> issue GitHub (diagnostic IA) sur incident
    ├── deploy-watch.sh    #   diagnostic d'échec de déploiement -> issue GitHub
    └── lib.sh             #   helpers partagés
```

---

## Bon à savoir (pièges connus)

- **Le `Caddyfile` est monté en *fichier unique*** dans le conteneur. Toute modification
  nécessite un `docker restart proxy_caddy` pour être prise en compte (un `reload` seul ne
  suffit pas : l'édition crée un nouvel inode que le bind-mount ne suit pas).
- **`projects.conf`** est insensible à la casse (`Labault/Hush` == `Labault/hush`).
- Le déploiement fait `git reset --hard origin/main` : tout changement local non poussé
  est écrasé. Les `deploy.sh` doivent donc être **committés** dans chaque projet.

---

## Aller plus loin

`dispatch.sh` est volontairement **déterministe** (rails). Le jugement (diagnostic d'échec,
revue de risque, audit) est délégué à des **agents en lecture seule** qui n'exécutent rien
et ouvrent des issues — voir [`ops/README.md`](ops/README.md). Roadmap de durcissement :
compte machine GitHub + clés lecture seule, socket-proxy Docker, sauvegarde distante (B2/S3),
limites de ressources persistées, IaC.
