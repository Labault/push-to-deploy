#!/bin/bash
set -euo pipefail
# Substitue ${WEBHOOK_SECRET} dans hooks.json avant de démarrer le listener.
sed "s|\${WEBHOOK_SECRET}|${WEBHOOK_SECRET}|g" /deploy/hooks.json > /tmp/hooks.json
exec webhook -hooks /tmp/hooks.json -port 9000 -verbose -hotreload
