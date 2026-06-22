#!/usr/bin/env bash
# Dispatcher central appelé par le listener webhook.
# Rôle : résoudre le dossier du projet à partir du nom du repo GitHub,
# mettre le code à jour (git), puis lancer le contrat ./deploy.sh du projet.
#
# IMPORTANT : on lance le déploiement en arrière-plan et on rend la main
# immédiatement — GitHub coupe la livraison du webhook après ~10s, or un
# build Docker dure plus longtemps. Le vrai déploiement continue, loggé.
set -euo pipefail

REPO="${1:-}"                 # ex: "thibault/hush" (repository.full_name)
CONF="/deploy/projects.conf"
LOGDIR="/deploy/logs"
mkdir -p "$LOGDIR"

if [ -z "$REPO" ]; then
  echo "dispatch: aucun repo fourni" >&2
  exit 2
fi

# Résolution du dossier : 1) table explicite projects.conf, 2) fallback /srv/<repo>
DIR=""
if [ -f "$CONF" ]; then
  DIR="$(grep -vE '^\s*#' "$CONF" | awk -F'=' -v r="$REPO" '
    { gsub(/[[:space:]]/, "", $1); gsub(/[[:space:]]/, "", $2) }
    tolower($1) == tolower(r) { print $2; exit }')"
fi
[ -z "$DIR" ] && DIR="/srv/$(basename "$REPO")"

if [ ! -d "$DIR/.git" ]; then
  echo "dispatch: $DIR n'est pas un clone git (repo $REPO)" >&2
  exit 3
fi

LOG="$LOGDIR/$(basename "$REPO").log"

# Clé de déploiement LECTURE SEULE, dédiée à CE repo (une clé par projet, montées
# dans /keys). Compromission du webhook => lecture d'un seul repo, pas d'écriture.
KEYNAME="$(basename "$REPO" | tr '[:upper:]' '[:lower:]')"
KEYFILE="/keys/${KEYNAME}.key"
if [ ! -f "$KEYFILE" ]; then
  echo "dispatch: aucune clé de déploiement pour $REPO (attendu $KEYFILE)" >&2
  exit 4
fi
export GIT_SSH_COMMAND="ssh -i $KEYFILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

# Déploiement détaché (survit à la fin de la requête webhook)
setsid bash -c '
  set -euo pipefail
  cd "'"$DIR"'"
  echo "===== $(date "+%F %T") deploy '"$REPO"' -> '"$DIR"' ====="
  # Les clones /srv appartiennent à deploy ; git tourne en root dans le conteneur
  git config --global --add safe.directory "'"$DIR"'"
  git fetch --prune origin
  git reset --hard origin/main
  # Le conteneur tourne en root : on remet les fichiers au propriétaire humain
  # unique (thibault, UID 1000) pour éviter tout mélange root/deploy.
  chown -R 1000:1000 "'"$DIR"'"
  chmod +x ./deploy.sh
  ./deploy.sh
  echo "===== $(date "+%F %T") done ====="
' >>"$LOG" 2>&1 < /dev/null &

echo "deploy de $REPO mis en file (voir $LOG)"
