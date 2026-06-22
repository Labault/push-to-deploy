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

1. **Une deploy key read-only par repo** (le webhook ne fait que lire — aucune écriture possible).
2. **Un contrat `deploy.sh` identique** dans chaque projet (interface uniforme,
   implémentation libre).
3. **Un listener webhook unique** dans `push-to-deploy`, exposé sur
   `deploy.labault.dev`.

---

## 1. Setup initial (une seule fois)

### a. Clés de déploiement (read-only, une par repo)

Le webhook ne fait que `git pull` → il n'a besoin que de **lecture**. Le modèle
retenu : **une *deploy key* GitHub en lecture seule par repo**, générée sans
passphrase, stockée dans `deploy/keys/<repo>.key` (gitignoré) et montée en lecture
seule dans le conteneur sous `/keys`. `dispatch.sh` choisit la bonne clé d'après le
nom du repo (`/keys/<repo-en-minuscules>.key`).

> **Pourquoi par repo et read-only ?** Une *deploy key* GitHub est unique à un repo
> et peut être limitée à la lecture. Résultat : compromettre le webhook ne donne
> que la **lecture d'un seul repo** — jamais d'écriture, jamais accès aux autres.
> C'est plus sûr qu'une clé personnelle (write sur tout) ou qu'une clé de compte
> machine partagée.

Génération + ajout en read-only (via [`gh`](https://cli.github.com), authentifié) :

```bash
mkdir -p deploy/keys && chmod 700 deploy/keys
NAME=monrepo ; REPO=owner/MonRepo            # NAME = basename en minuscules
ssh-keygen -t ed25519 -N "" -C "vps-webhook-ro-$NAME" -f deploy/keys/$NAME.key
gh repo deploy-key add deploy/keys/$NAME.key.pub -R "$REPO" --title vps-webhook-ro
#   (read-only par défaut ; surtout PAS --allow-write)
```

### b. Variables d'environnement

```bash
cd ~/push-to-deploy
cp .env.exemple .env   # si pas déjà fait
# Édite .env :
#   LETSENCRYPT_EMAIL=<ton email>
#   WEBHOOK_SECRET=<openssl rand -hex 32>
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

1. **Cloner sur le VPS** dans `/srv/<repo>` (si pas déjà fait) :
   ```bash
   git clone git@github.com:<owner>/<repo>.git /srv/<repo>
   ```
   > À chaque déploiement, `dispatch.sh` fait un `git reset --hard origin/main` puis
   > `chown` du clone vers l'utilisateur applicatif (propriété stable, pas de mélange root).

   Puis génère sa **deploy key read-only** (cf. §1.a) :
   ```bash
   N=$(basename "<repo>" | tr 'A-Z' 'a-z')
   ssh-keygen -t ed25519 -N "" -C "vps-webhook-ro-$N" -f ~/push-to-deploy/deploy/keys/$N.key
   gh repo deploy-key add ~/push-to-deploy/deploy/keys/$N.key.pub -R "<owner>/<repo>" --title vps-webhook-ro
   ```

2. **Ajouter le contrat de déploiement** au repo :
   ```bash
   cp ~/push-to-deploy/deploy/deploy.sh.template /srv/<repo>/deploy.sh
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

3. **Enregistrer la route** dans `push-to-deploy/deploy/projects.conf` :
   ```
   <owner>/<repo> = /srv/<repo>
   ```
   (sinon fallback automatique sur `/srv/<repo>`). Le matching est **insensible à
   la casse** : `Owner/MonRepo` correspond à `owner/monrepo`.

4. **Créer le webhook GitHub** (repo → Settings → Webhooks → Add webhook) :
   - **Payload URL** : `https://deploy.labault.dev/hooks/deploy`
   - **Content type** : `application/json`
   - **Secret** : la valeur de `WEBHOOK_SECRET`
   - **Events** : *Just the push event*

5. **Tester** : `git commit --allow-empty -m "test deploy" && git push`,
   puis sur le VPS :
   ```bash
   docker compose logs -f webhook            # réception + déclenchement
   tail -f ~/push-to-deploy/deploy/logs/<repo>.log   # déroulé du build/up
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
