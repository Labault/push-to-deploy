#!/usr/bin/env bash
# Diagnostic d'échec de déploiement : surveille les logs du webhook ; à chaque
# nouvel "ÉCHEC ✗", déclenche un diagnostic IA + ouvre une issue GitHub. Si un
# déploiement réussit ensuite ("Déploiement terminé ✓"), ferme l'issue.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
LOGDIR="$(dirname "$0")/../deploy/logs"
exec >>"$HOME/ops/deploy-watch.log" 2>&1

echo "===== $(date '+%F %T') deploy-watch ====="
for f in "$LOGDIR"/*.log; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .log)"                 # ex: Humelis, red-flag-bingo, LaOuLonVa
  sizef="$STATE_DIR/dwatch-$base.size"
  prev="$(cat "$sizef" 2>/dev/null || echo 0)"
  cur="$(wc -c < "$f")"
  echo "$cur" > "$sizef"
  [ "$cur" -le "$prev" ] && continue           # rien de nouveau (ou rotation)
  newpart="$(tail -c +$((prev+1)) "$f")"
  title="🛠️ [deploy] échec — $base"

  # Un déploiement réussi APRÈS coup ferme l'issue d'échec.
  printf '%s' "$newpart" | grep -q "Déploiement terminé ✓" && \
    issue_resolve "$title" "✅ Un déploiement ultérieur a réussi le $(date '+%F %T')."

  # Nouvel échec -> diagnostic + issue.
  printf '%s' "$newpart" | grep -q "ÉCHEC" || continue
  echo "  $base : ÉCHEC détecté"
  ctx="$(tail -c 6000 "$f")"
  diag="$(claude_diagnose "Tu es expert DevOps (Docker, Symfony/FrankenPHP, Astro, Node, WordPress). Le déploiement automatique du projet '$base' a ÉCHOUÉ. À partir UNIQUEMENT du log ci-dessous, réponds en français : 1) cause racine, 2) correctif concret (fichier concerné + changement à faire). Bref et actionnable.

Log de déploiement :
$ctx")"
  issue_open_once "$title" "**Échec de déploiement : \`$base\`** — $(date '+%F %T').

### 🤖 Diagnostic (IA, lecture seule)
${diag:-_diagnostic indisponible (timeout IA)_}

<details><summary>Extrait du log de déploiement</summary>

\`\`\`
$ctx
\`\`\`
</details>

> Issue auto-générée à la détection de \`ÉCHEC ✗\`. Corrige, pousse sur main : le déploiement repassera et fermera l'issue."
done
