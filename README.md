# proxy-global

Reverse proxy Caddy partagé pour les projets hébergés sur le VPS.

## Architecture

- Caddy 2 (alpine) écoute sur 80/443 (TLS auto via Let's Encrypt).
- Réseau Docker externe `web` partagé avec les projets backend.
- Chaque projet rejoint le réseau `web` et n'expose plus de ports sur l'hôte.

## Setup initial sur le VPS

```bash
# Créer le réseau partagé (une seule fois)
docker network create web

# Cloner ce repo
git clone git@github.com:USER/proxy-global.git ~/proxy-global
cd ~/proxy-global

# Configurer
cp .env.example .env
# Éditer .env : LETSENCRYPT_EMAIL=...

# Démarrer
docker compose up -d

# Logs
docker compose logs -f caddy
```

## Ajouter un projet

1. Le projet rejoint le réseau `web` dans son `docker-compose.yml`.
2. Le projet n'expose plus de ports publics.
3. Ajouter un bloc dans le `Caddyfile` :
mon-projet.example.com {
    import security_headers
    reverse_proxy mon_service:80
}
4. Recharger Caddy : `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`
