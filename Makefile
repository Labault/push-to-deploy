# Makefile — push-to-deploy (proxy global Caddy + listener de déploiement)
# Raccourcis d'exploitation. Le binaire caddy n'est PAS requis en local :
# fmt/validate passent par un conteneur caddy:2-alpine jetable (même invocation
# que proxy-deploy.sh). `make` seul affiche l'aide.

COMPOSE   ?= docker compose
CADDY_IMG ?= caddy:2-alpine
CADDYFILE ?= Caddyfile

# .env présent (serveur) → on le passe à caddy ; sinon placeholder (validate local)
CADDY_ENV := $(if $(wildcard .env),--env-file .env,-e LETSENCRYPT_EMAIL=placeholder@example.com)

# Domaines servis — liste de référence pour le smoke test post-déploiement.
DOMAINS ?= redflagbingo.fun humelis.labault.dev labault.dev www.labault.dev \
           hush.labault.dev devspeak.labault.dev lolv.labault.dev \
           tibec.labault.dev deploy.labault.dev

.DEFAULT_GOAL := help
.PHONY: help deploy validate fmt fmt-check check up down recreate \
        caddy-recreate webhook-build ps logs caddy-logs webhook-logs \
        deploy-logs smoke

help: ## Affiche cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── Déploiement ────────────────────────────────────────────────────────────
deploy: ## Déploie le proxy (git pull → validate → force-recreate caddy)
	./proxy-deploy.sh

# ── Caddyfile ──────────────────────────────────────────────────────────────
validate: ## Valide le Caddyfile (conteneur jetable, sur le fichier courant)
	docker run --rm $(CADDY_ENV) \
	  -v "$(CURDIR)/$(CADDYFILE):/etc/caddy/Caddyfile:ro" \
	  $(CADDY_IMG) caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

fmt: ## Formate le Caddyfile en place (caddy fmt --overwrite)
	docker run --rm -v "$(CURDIR)/$(CADDYFILE):/etc/caddy/Caddyfile" \
	  $(CADDY_IMG) caddy fmt --overwrite /etc/caddy/Caddyfile

fmt-check: ## Vérifie le formatage sans modifier (échoue si non formaté)
	@docker run --rm -v "$(CURDIR)/$(CADDYFILE):/etc/caddy/Caddyfile:ro" \
	  $(CADDY_IMG) caddy fmt /etc/caddy/Caddyfile >/dev/null

check: validate fmt-check ## validate + fmt-check (à passer avant un commit Caddyfile)
	@echo "Caddyfile OK ✓"

# ── Conteneurs ─────────────────────────────────────────────────────────────
up: ## Démarre la stack (proxy + webhook)
	$(COMPOSE) up -d

down: ## Arrête la stack
	$(COMPOSE) down

recreate: ## Recrée toute la stack (force-recreate)
	$(COMPOSE) up -d --force-recreate

caddy-recreate: ## Recrée uniquement caddy (reprend le Caddyfile bind-mount)
	$(COMPOSE) up -d --force-recreate caddy

webhook-build: ## Rebuild + relance le listener webhook
	$(COMPOSE) up -d --build webhook

ps: ## État des conteneurs
	$(COMPOSE) ps

# ── Logs ───────────────────────────────────────────────────────────────────
logs: ## Suit les logs de toute la stack
	$(COMPOSE) logs -f --tail=50

caddy-logs: ## Suit les logs de caddy
	$(COMPOSE) logs -f --tail=50 caddy

webhook-logs: ## Suit les logs du listener webhook
	$(COMPOSE) logs -f --tail=50 webhook

deploy-logs: ## Suit les logs des déploiements d'apps (deploy/logs/*.log)
	tail -f deploy/logs/*.log

# ── Vérif ──────────────────────────────────────────────────────────────────
smoke: ## curl -I sur tous les domaines servis (code HTTP attendu = 2xx/3xx)
	@for d in $(DOMAINS); do \
	  code=$$(curl -sS -o /dev/null -w '%{http_code}' -I -m 12 "https://$$d/" 2>/dev/null || echo ERR); \
	  printf '  %-26s %s\n' "$$d" "$$code"; \
	done
