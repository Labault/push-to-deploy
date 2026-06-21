# Déploiement standardisé

Pipeline de déploiement uniforme pour tous les projets du VPS, quelle que soit
leur stack (Symfony, Astro, WordPress, statique…).

## Principe

```
GitHub (push main)
   │  POST webhook  +  signature HMAC (X-Hub-Signature-256)
   ▼
https://deploy.labault.dev/hooks/deploy   →   Caddy   →   conteneur `webhook`
   │  vérifie le secret + ref == main
   ▼
deploy/dispatch.sh   (résout repo → dossier, git pull, lance deploy.sh)
   ▼
/srv/<projet>/deploy.sh   ← MÊME contrat partout (build + up + healthcheck)
```

Trois piliers :

1. **Une seule clé deployer** (compte machine GitHub) qui pull tous les repos.
2. **Un contrat `deploy.sh` identique** dans chaque projet (interface uniforme,
   implémentation libre).
3. **Un listener webhook unique** dans `proxy-global`, exposé sur
   `deploy.labault.dev`.

---

## 1. Setup initial (une seule fois)

### a. Compte machine GitHub + clé unique

GitHub interdit de réutiliser une *deploy key* sur plusieurs repos — d'où
l'ancien problème d'une clé par projet. La solution : **un compte machine**
(ex. `labault-deploy`) avec **une seule** clé, ajouté en lecture sur tous
les repos.

```bash
# Sur le VPS, en tant qu'utilisateur deploy :
sudo -iu deploy
ssh-keygen -t ed25519 -C "labault-deploy" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub   # → à copier
```

- Crée (ou réutilise) un compte GitHub dédié `labault-deploy`.
- Profil GitHub du bot → **Settings → SSH and GPG keys → New SSH key** → colle
  la clé publique.
- Donne au bot l'accès **read** à chaque repo (invite-le comme collaborateur,
  ou mets tes repos dans une organisation et ajoute-le à une équipe *read*).

> Le chemin de la clé privée doit correspondre à `DEPLOYER_SSH_KEY` dans `.env`
> (par défaut `/home/deploy/.ssh/id_ed25519`).

### b. Variables d'environnement

```bash
cd ~/proxy-global
cp .env.exemple .env   # si pas déjà fait
# Édite .env :
#   WEBHOOK_SECRET=<openssl rand -hex 32>
#   DEPLOYER_SSH_KEY=/home/deploy/.ssh/id_ed25519
```

### c. Démarrer le listener

```bash
docker compose up -d --build webhook
docker compose logs -f webhook   # doit afficher "serving hooks on ..."
```

### d. DNS

Ajoute un enregistrement `deploy.labault.dev` → IP du VPS (comme tes autres
sous-domaines). Caddy obtiendra le certificat tout seul au premier accès.

---

## 2. Onboarder un projet

Pour chaque projet à passer en déploiement auto :

1. **Cloner sur le VPS avec la clé deployer** (si pas déjà fait) :
   ```bash
   sudo -iu deploy
   git clone git@github.com:<owner>/<repo>.git /srv/<repo>
   ```

2. **Ajouter le contrat de déploiement** au repo :
   ```bash
   cp ~/proxy-global/deploy/deploy.sh.template /srv/<repo>/deploy.sh
   # adapte le bloc "ÉTAPES SPÉCIFIQUES PROJET" si besoin (migrations…)
   # commit + push : deploy.sh est versionné avec le projet
   ```
   Vérifie aussi que le `docker-compose.yml` du projet :
   - rejoint le réseau externe `web`,
   - n'expose pas de port public,
   - porte un `container_name` qui matche le `reverse_proxy` du `Caddyfile`.

   (Optionnel) un `.deploy.env` non versionné pour activer le healthcheck :
   ```
   HEALTHCHECK_URL=https://<projet>.labault.dev/
   ```

3. **Enregistrer la route** dans `proxy-global/deploy/projects.conf` :
   ```
   <owner>/<repo> = /srv/<repo>
   ```
   (sinon fallback automatique sur `/srv/<repo>`)

4. **Créer le webhook GitHub** (repo → Settings → Webhooks → Add webhook) :
   - **Payload URL** : `https://deploy.labault.dev/hooks/deploy`
   - **Content type** : `application/json`
   - **Secret** : la valeur de `WEBHOOK_SECRET`
   - **Events** : *Just the push event*

5. **Tester** : `git commit --allow-empty -m "test deploy" && git push`,
   puis sur le VPS :
   ```bash
   docker compose logs -f webhook            # réception + déclenchement
   tail -f ~/proxy-global/deploy/logs/<repo>.log   # déroulé du build/up
   ```

---

## Lancer un déploiement à la main

Le contrat reste utilisable en SSH, sans webhook :

```bash
cd /srv/<repo> && git pull && ./deploy.sh
```

## Sécurité — à savoir

- Le conteneur `webhook` monte le **socket Docker** : il a de fait les droits
  root sur l'hôte. C'est nécessaire pour piloter les stacks, mais ça veut dire
  que le secret HMAC et l'accès réseau à `deploy.labault.dev` doivent rester
  sérieux (le secret protège déjà l'endpoint : sans signature valide, rien ne
  s'exécute).
- Seuls les push sur `main` déclenchent un déploiement (règle dans `hooks.json`).
- Le `WEBHOOK_SECRET` et la clé privée ne sont jamais commités (`.gitignore`).

## Aller plus loin

La logique de `dispatch.sh` est volontairement simple et déterministe. C'est
le point d'extension naturel pour, plus tard, brancher un agent (rollback
automatique si le healthcheck échoue, notification, déploiement par tag…).
