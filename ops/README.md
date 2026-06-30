# ops — exploitation

Tooling d'exploitation du VPS, piloté par `cron`. Trois briques, un principe directeur :

> **Rails déterministes pour exécuter, agents IA en lecture seule pour juger.**
> La collecte (docker/curl) et les actions (issues GitHub) sont déterministes ;
> l'IA reçoit le contexte **en texte** et tourne **sans aucun outil** → elle
> diagnostique mais n'exécute rien. Aucune surface d'injection de prompt vers le système.

## Briques

| Script | Rôle | Cadence |
|---|---|---|
| [`backup.sh`](backup.sh) | Sauvegarde **chiffrée** (`restic`) : dump de toutes les bases (PostgreSQL + MariaDB) + données non reconstructibles + cette tooling | quotidien |
| [`uptime-check.sh`](uptime-check.sh) | Moniteur HTTP des sites. Sur bascule **UP→DOWN** : diagnostic IA + ouverture d'une **issue GitHub** ; fermeture auto au retour | toutes les 5 min |
| [`deploy-watch.sh`](deploy-watch.sh) | Surveille les logs du webhook. Sur **`ÉCHEC ✗`** : diagnostic IA + **issue GitHub** ; fermeture au prochain déploiement réussi | toutes les 3 min |
| [`lib.sh`](lib.sh) | Helpers partagés : issues dédupliquées (anti-spam), appel Claude headless borné | — |

L'IA ne tourne **que sur incident** (rare) → coût négligeable. En cas d'indisponibilité de
l'IA, l'issue s'ouvre quand même (mention « diagnostic indisponible ») : **dégradation gracieuse**.

> ⚠️ **`OPS_REPO` DOIT pointer un repo privé.** Le défaut est `Labault/ops-incidents` (privé)
> précisément pour que l'outil ne publie **jamais** une alerte sur un repo public. Override
> possible via la variable d'environnement `OPS_REPO`, mais la cible reste **toujours privée** :
> les issues portent host, conteneur et code HTTP, et un diagnostic IA qui peut citer une ligne
> de log. C'est aussi du fail-closed — un tiers qui clone l'outil n'a pas les droits sur ce repo,
> donc rien ne fuite chez autrui.

## Crontab type

```cron
30 3 * * *   /home/<user>/push-to-deploy/ops/backup.sh
*/5 * * * *  /home/<user>/push-to-deploy/ops/uptime-check.sh
*/3 * * * *  /home/<user>/push-to-deploy/ops/deploy-watch.sh
```

## Prérequis (binaires dans `~/.local/bin`, sans sudo)

_Versions testées entre parenthèses._

- [`restic`](https://restic.net) (`0.19.0`) — sauvegardes chiffrées dédupliquées.
- [`gh`](https://cli.github.com) (`2.95.0`) authentifié par un **PAT fine-grained** limité au seul
  repo `ops-incidents`, permission **Issues (read and write)** — ouverture des issues.
- [`claude`](https://docs.claude.com/claude-code) (`2.1.185`) authentifié — diagnostic IA headless (`claude -p`).

## États & secrets (hors-git)

Le code est versionné ici ; **l'état runtime et les secrets restent dans `~/ops/`**, jamais
dans le dépôt :

```
~/ops/
├── .restic-pass     # mot de passe du dépôt restic (chmod 600) — à sauvegarder HORS serveur !
├── state/           # état des moniteurs (UP/DOWN, offsets de logs)
├── *.log            # journaux d'exécution
└── (les *.sh vivent dans push-to-deploy/ops/, versionnés)
```

## Restauration d'une sauvegarde

```bash
export RESTIC_REPOSITORY=~/backups/restic RESTIC_PASSWORD_FILE=~/ops/.restic-pass
restic snapshots                      # lister
restic restore latest --target /tmp/restore
# puis réimporter un dump, ex. Postgres :
docker exec -i <db_container> psql -U <user> < /tmp/restore/.../<db>.sql
```

## Limites assumées

- **Dépôt restic local** (même VPS) : protège contre corruption/suppression, **pas** contre
  la perte totale du serveur. Compléter par un dépôt distant (Backblaze B2 / S3).
- **Moniteur auto-hébergé** : si le VPS entier tombe, il ne peut pas alerter sur sa propre
  mort. Compléter par un *dead-man's-switch* externe (healthchecks.io / UptimeRobot).
