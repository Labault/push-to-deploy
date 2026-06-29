#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────
# Déploiement du proxy GLOBAL (ce repo, checkout dans ~/proxy-global).
#
# Distinct du pipeline webhook : celui-ci déploie les APPS hébergées (/srv/*),
# le proxy lui-même se déploie À LA MAIN avec ce script. Pourquoi pas en auto :
# c'est de l'infra PARTAGÉE (un Caddyfile cassé tombe tous les sites) → on garde
# un humain dans la boucle et une validation BLOQUANTE avant d'appliquer.
#
# Séquence : git pull → caddy validate (sur le NOUVEAU fichier) → recréation.
# La recréation (et pas un reload) est obligatoire : le Caddyfile est un
# bind-mount single-file ; l'éditer crée un nouvel inode qu'un `caddy reload`
# (ou un `docker compose up -d` seul) ne reprend pas. Seul --force-recreate
# re-bind le fichier.
# ─────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

log() { echo "[$(date '+%H:%M:%S')] [proxy-deploy] $*"; }

log "Alignement sur origin/main…"
git pull --ff-only

# ── Garde-fou : valider le NOUVEAU Caddyfile dans un conteneur jetable, qui
# monte le fichier courant (inode frais) — surtout PAS le conteneur en cours
# (il sert l'ancien inode). Un fichier invalide => on abort AVANT de toucher au
# proxy en prod, donc aucune app ne tombe.
log "Validation du Caddyfile…"
docker run --rm --env-file .env \
  -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

# ── Application : RECRÉATION du conteneur caddy (re-bind du nouveau fichier).
log "Recréation du conteneur caddy…"
docker compose up -d --force-recreate caddy

log "Proxy déployé ✓ — vérifie : docker compose logs --tail=20 caddy"
