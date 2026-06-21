# Listener de déploiement : reçoit les webhooks GitHub et lance le deploy
# du bon projet. Construit sur l'image docker:cli pour piloter le démon
# Docker de l'hôte via le socket monté en volume.
FROM docker:27-cli

# Outils nécessaires au dispatcher : git (pull), ssh (clé deployer),
# bash/curl (scripts + healthcheck), tini (PID 1 propre).
RUN apk add --no-cache bash curl git openssh-client tini

# Plugin docker compose v2 (installé en binaire pour ne pas dépendre des repos apk)
ARG COMPOSE_VERSION=v2.29.7
RUN mkdir -p /usr/local/lib/docker/cli-plugins && \
    wget -qO /usr/local/lib/docker/cli-plugins/docker-compose \
      "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" && \
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Binaire adnanh/webhook
ARG WEBHOOK_VERSION=2.8.2
RUN wget -qO /tmp/webhook.tar.gz \
      "https://github.com/adnanh/webhook/releases/download/${WEBHOOK_VERSION}/webhook-linux-amd64.tar.gz" && \
    tar -xzf /tmp/webhook.tar.gz -C /tmp && \
    mv /tmp/webhook-linux-amd64/webhook /usr/local/bin/webhook && \
    chmod +x /usr/local/bin/webhook && \
    rm -rf /tmp/webhook*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/entrypoint.sh"]
