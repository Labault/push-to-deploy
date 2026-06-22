# push-to-deploy

An all-in-one infrastructure repo that **serves and deploys every app on a single
VPS**: a **shared TLS reverse proxy (Caddy)** + **webhook-driven continuous
deployment** + **operations tooling** (encrypted backups, uptime monitoring,
AI-assisted incident diagnosis). One small repo drives the whole server.

> Built for a single-VPS box hosting several heterogeneous apps
> (Symfony/FrankenPHP, Astro, Node, WordPress, static sites) behind one proxy,
> with an identical deploy flow regardless of the stack.

**Running in production** on my own VPS — it's what serves
[Hush](https://hush.labault.dev), [Red Flag Bingo](https://redflagbingo.fun) and
other projects. Not a demo: this is the real deployment pipeline behind my apps.

---

## Overview

```
                    Internet
                       │ 80/443 (auto TLS, Let's Encrypt)
                       ▼
        ┌──────────────────────────────┐
        │   Caddy (proxy_caddy)         │  reverse proxy + HTTPS + security headers
        │   *.example.dev, example.dev  │
        └───────┬───────────────┬───────┘
                │ docker network │
                │     « web »    │
     ┌──────────┴───┐      ┌─────┴───────────────────────────┐
     │  apps         │      │  deploy.example.dev             │
     │  (containers) │      │     ▼                           │
     │  Symfony,     │      │  webhook (proxy_webhook)        │ ← CD listener
     │  Astro, WP…   │      │     ▼ dispatch.sh               │
     └───────────────┘      │  git pull + ./deploy.sh         │
                            └─────────────────────────────────┘

Continuous deployment:  git push main ──▶ GitHub webhook (HMAC) ──▶ dispatch.sh
                        ──▶ git reset --hard origin/main ──▶ ./deploy.sh (build + up + healthcheck)
```

Three building blocks:

| Block | Role | Where |
|---|---|---|
| **Reverse proxy** | Auto TLS, `*.domain` routing, security headers | [`Caddyfile`](Caddyfile), [`docker-compose.yml`](docker-compose.yml) |
| **Continuous deployment** | `push main` → build + redeploy of the affected app | [`deploy/`](deploy/) ([README](deploy/README.md)) |
| **Operations** | Encrypted backups + monitoring + AI diagnosis | [`ops/`](ops/) ([README](ops/README.md)) |

---

## Deployment in one sentence

**You push to `main`, and the app redeploys itself on the VPS** — whatever its
tech stack. Each project ships a `deploy.sh` script (same contract everywhere:
build → optional migrations → `up` → **blocking HTTP healthcheck**); the central
webhook triggers it after aligning the code with `origin/main`.

Full details and the onboarding procedure for a new project:
**[`deploy/README.md`](deploy/README.md)**.

---

## Security model

- **TLS** automated (Let's Encrypt) + uniform security headers (HSTS, nosniff,
  anti-clickjacking…) via the `(security_headers)` snippet in the `Caddyfile`.
- **Databases** are never publicly exposed (private per-app `internal` Docker
  networks).
- **Signed webhook**: only a `POST` with a valid HMAC-SHA256 signature
  (`WEBHOOK_SECRET`) **and** `ref == refs/heads/main` triggers a deploy.
- **Read-only deploy keys, one per repo**: the webhook only ever `pull`s, so it
  carries dedicated **read-only** GitHub deploy keys (in `deploy/keys/`, mounted
  at `/keys`). A compromised key grants only **read access to a single repo** —
  no write, no access to the others.
- ⚠️ The `webhook` container mounts the **Docker socket**, so it effectively has
  **root** on the host (needed to drive the stacks). It's the most sensitive
  component — protected by the HMAC secret. Planned hardening: Docker
  *socket-proxy*, GitHub IP allowlist at the Caddy level.
- **Secrets out of git**: `.env` (HMAC secret, email) and the private keys are
  **never** committed (`.gitignore`). Production `.env` files are `chmod 600`.

---

## Quick start (VPS setup)

```bash
# 1. Shared network (once)
docker network create web

# 2. Clone and configure
git clone git@github.com:<owner>/push-to-deploy.git ~/push-to-deploy
cd ~/push-to-deploy
cp .env.example .env          # set: LETSENCRYPT_EMAIL, WEBHOOK_SECRET

# 3. Start the proxy + the deploy listener
docker compose up -d

# 4. (optional) install the operations tooling -> see ops/README.md
```

To wire a project into auto-deploy: **[`deploy/README.md`](deploy/README.md)**.

---

## Repository structure

```
push-to-deploy/
├── Caddyfile              # routing + TLS + security headers (one block per site)
├── docker-compose.yml     # caddy + webhook services, « web » network, volumes
├── .env(.example)         # LETSENCRYPT_EMAIL, WEBHOOK_SECRET (out of git)
├── deploy/                # continuous deployment
│   ├── dispatch.sh        #   resolves repo→folder, git reset --hard, runs ./deploy.sh
│   ├── projects.conf      #   routing table  owner/repo = /srv/<folder>
│   ├── hooks.json         #   listener rules (HMAC + ref==main)
│   ├── deploy.sh.template #   reference deploy contract (copied per project)
│   ├── keys/              #   read-only deploy keys, one per repo (out of git)
│   └── webhook/           #   listener image (adnanh/webhook + docker CLI + git)
└── ops/                   # operations (cron) — see ops/README.md
    ├── backup.sh          #   encrypted restic backup (databases + data + tooling)
    ├── uptime-check.sh    #   HTTP monitoring -> GitHub issue (AI diagnosis) on incident
    ├── deploy-watch.sh    #   deploy-failure diagnosis -> GitHub issue
    └── lib.sh             #   shared helpers
```

---

## Stack & versions

| Component | Version | Source |
|---|---|---|
| Caddy | `2-alpine` | official image |
| adnanh/webhook | `2.8.2` | [`deploy/webhook/Dockerfile`](deploy/webhook/Dockerfile) |
| Docker Compose (listener plugin) | `v2.29.7` | same |
| Listener base image | `docker:27-cli` | same |
| Ops tools (`restic` / `gh` / `claude`) | `0.19.0` / `2.95.0` / `2.1.185` | [`ops/README.md`](ops/README.md) |

---

## Good to know (known gotchas)

- **The `Caddyfile` is mounted as a *single file*** in the container. Any change
  needs a `docker restart proxy_caddy` to take effect (a `reload` alone isn't
  enough: editing creates a new inode the bind-mount doesn't follow).
- **`projects.conf`** is case-insensitive (`Labault/Hush` == `Labault/hush`).
- The deploy runs `git reset --hard origin/main`: any unpushed local change is
  overwritten. So each project's `deploy.sh` must be **committed**.

---

## Going further

`dispatch.sh` is deliberately **deterministic** (rails). Judgment (failure
diagnosis, risk review, audit) is delegated to **read-only agents** that execute
nothing and open issues — see [`ops/README.md`](ops/README.md). Hardening
roadmap: Docker socket-proxy, remote backups (B2/S3), persisted resource limits,
IaC.

---

## License

See [LICENSE](LICENSE).

