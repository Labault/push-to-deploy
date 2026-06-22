#!/usr/bin/env bash
# Sauvegarde chiffrée (restic) : dumps de toutes les bases + données applicatives.
# Cron quotidien. Dépôt LOCAL pour l'instant -> à doubler d'un dépôt distant (B2/S3).
set -uo pipefail
export PATH="$HOME/.local/bin:$PATH"
export RESTIC_REPOSITORY="$HOME/backups/restic"
export RESTIC_PASSWORD_FILE="$HOME/ops/.restic-pass"

LOG="$HOME/ops/backup.log"
exec >>"$LOG" 2>&1
echo "===== $(date '+%F %T') démarrage backup ====="

DUMP="$(mktemp -d)"
trap 'rm -rf "$DUMP"' EXIT

# --- PostgreSQL (dump logique complet par instance) ---
for c in humelis_db rfb_db hush-postgres-prod; do
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then
    user="$(docker exec "$c" printenv POSTGRES_USER 2>/dev/null || echo postgres)"
    if docker exec "$c" pg_dumpall -U "$user" > "$DUMP/${c}.sql" 2>/dev/null; then
      echo "  ✓ dump $c ($(wc -c <"$DUMP/${c}.sql") o)"
    else
      echo "  ✗ ÉCHEC dump $c"; rm -f "$DUMP/${c}.sql"
    fi
  fi
done

# --- MariaDB (lolv) ---
if docker ps --format '{{.Names}}' | grep -qx lolv_db_prod; then
  rootpw="$(docker exec lolv_db_prod printenv MARIADB_ROOT_PASSWORD 2>/dev/null)"
  if docker exec -e MYSQL_PWD="$rootpw" lolv_db_prod sh -c 'mariadb-dump -uroot --all-databases --single-transaction' > "$DUMP/lolv_db_prod.sql" 2>/dev/null; then
    echo "  ✓ dump lolv_db_prod ($(wc -c <"$DUMP/lolv_db_prod.sql") o)"
  else
    echo "  ✗ ÉCHEC dump lolv_db_prod"; rm -f "$DUMP/lolv_db_prod.sql"
  fi
fi

# --- Tooling ops + planification (pour pouvoir tout reconstruire) ---
cp "$(dirname "$0")"/*.sh "$DUMP/" 2>/dev/null
crontab -l > "$DUMP/crontab.txt" 2>/dev/null

# --- Sauvegarde restic : dumps SQL + données non reconstructibles ---
restic backup --tag auto --host vps \
  "$DUMP" \
  /srv/laoulonva/wp-content \
  /srv/portfolio \
  && echo "  ✓ snapshot restic créé"

# --- Rétention ---
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6 >/dev/null \
  && echo "  ✓ rétention appliquée (7j/4s/6m)"

echo "===== $(date '+%F %T') fin backup ====="
