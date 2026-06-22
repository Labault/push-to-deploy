#!/usr/bin/env bash
# Helpers partagés des briques de monitoring (uptime + diagnostic de déploiement).
# Principe sécurité : Claude reçoit TOUT le contexte en texte et tourne SANS outil
# (--output-format text, pas de --dangerously-skip-permissions) → il raisonne mais
# n'exécute rien. Aucune surface d'injection de prompt vers le système.
export HOME="${HOME:-/home/thibault}"
export PATH="$HOME/.local/bin:$PATH"

OPS_REPO="Labault/proxy-global"          # repo central des alertes ops
STATE_DIR="$HOME/ops/state"
mkdir -p "$STATE_DIR"

# Diagnostic IA en lecture seule (borné en temps et en taille de sortie).
claude_diagnose() {
  timeout 150 claude -p "$1" --output-format text 2>/dev/null | head -c 4000
}

# --- Issues GitHub avec déduplication (anti-spam) ---
_issue_find_open() {   # titre exact -> numéro (ou vide)
  gh issue list -R "$OPS_REPO" --state open -L 80 --json number,title \
    --jq ".[] | select(.title==\"$1\") | .number" 2>/dev/null | head -1
}
issue_open_once() {    # titre  corps  : crée si aucune issue ouverte de même titre
  local n; n="$(_issue_find_open "$1")"
  [ -n "$n" ] && { echo "  issue déjà ouverte (#$n)"; return 0; }
  gh issue create -R "$OPS_REPO" --title "$1" --body "$2" >/dev/null 2>&1 \
    && echo "  issue créée" || echo "  ÉCHEC création issue"
}
issue_resolve() {      # titre  commentaire : commente + ferme si ouverte
  local n; n="$(_issue_find_open "$1")"
  [ -z "$n" ] && return 0
  gh issue comment -R "$OPS_REPO" "$n" --body "$2" >/dev/null 2>&1
  gh issue close   -R "$OPS_REPO" "$n" >/dev/null 2>&1
  echo "  issue #$n résolue"
}
