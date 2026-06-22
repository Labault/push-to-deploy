#!/usr/bin/env bash
# Moniteur "Uptime" : vérifie chaque site (HTTP), et SUR TRANSITION up->down
# déclenche un diagnostic IA + ouvre une issue GitHub ; ferme l'issue au retour.
# L'IA ne tourne QUE sur la bascule (rare) -> coût négligeable.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
exec >>"$HOME/ops/uptime.log" 2>&1

# host | url attendue 2xx/3xx | conteneur associé (pour le contexte de diagnostic)
CHECKS="
humelis|https://humelis.labault.dev/health|humelis_app
devspeak|https://devspeak.labault.dev/api/health|devspeak
hush|https://hush.labault.dev/|hush-web-prod
redflagbingo|https://redflagbingo.fun/|rfb_app
portfolio|https://labault.dev/|proxy_caddy
lolv|https://lolv.labault.dev/|lolv_wp_prod
"

# 2 tentatives pour éviter les faux positifs transitoires.
http_code() {
  local c=000
  for _ in 1 2; do
    c=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || echo 000)
    [ "$c" -ge 200 ] 2>/dev/null && [ "$c" -lt 400 ] 2>/dev/null && { echo "$c"; return 0; }
    sleep 3
  done
  echo "$c"; return 1
}

echo "===== $(date '+%F %T') uptime ====="
printf '%s\n' "$CHECKS" | while IFS='|' read -r host url cont; do
  [ -z "$host" ] && continue
  sf="$STATE_DIR/up-$host"; prev="$(cat "$sf" 2>/dev/null || echo UP)"
  title="🔴 [uptime] $host est DOWN"

  if code="$(http_code "$url")"; then
    echo "  $host UP ($code)"
    [ "$prev" = DOWN ] && issue_resolve "$title" "✅ **Rétabli** le $(date '+%F %T') — HTTP $code. Site de nouveau joignable."
    echo UP > "$sf"
  else
    echo "  $host DOWN ($code)"
    if [ "$prev" != DOWN ]; then
      ctx="Site        : $host ($url)
Conteneur   : $cont
Statut      : $(docker ps -a --filter "name=^${cont}$" --format '{{.Status}}' 2>/dev/null)
Healthcheck : $(docker inspect "$cont" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' 2>/dev/null)
Code HTTP   : $code (attendu 2xx/3xx)

Derniers logs ($cont) :
$(docker logs "$cont" --tail 40 2>&1 | tail -40)"
      diag="$(claude_diagnose "Tu es ingénieur SRE. Un site est DOWN. À partir UNIQUEMENT du contexte ci-dessous, réponds en français et de façon concise : 1) cause la plus probable, 2) commande ou correctif concret pour rétablir. Ne propose rien hors de ce que le contexte permet de déduire.

$ctx")"
      issue_open_once "$title" "**$host injoignable** ($url) — détecté le $(date '+%F %T').

### 🤖 Diagnostic (IA, lecture seule)
${diag:-_diagnostic indisponible (timeout IA)_}

<details><summary>Contexte brut</summary>

\`\`\`
$ctx
\`\`\`
</details>

> Issue auto-générée par le moniteur uptime — se fermera seule au rétablissement."
    fi
    echo DOWN > "$sf"
  fi
done
