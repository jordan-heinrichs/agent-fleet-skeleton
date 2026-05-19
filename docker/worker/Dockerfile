# syntax=docker/dockerfile:1.6
# agent-fleet-skeleton — Worker container.
#
# Stateless. BRPOP a job, run `claude --print` with the role brief, push result.
# Multiple worker containers run in parallel via docker-compose deploy.replicas.

FROM node:20-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git \
      tini \
      ca-certificates \
      curl \
      jq \
      redis-tools \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@latest

ARG USER_UID=1000
ARG USER_GID=1000
RUN userdel -r node 2>/dev/null || true \
 && groupdel node 2>/dev/null || true \
 && groupadd --gid ${USER_GID} fleet \
 && useradd  --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash fleet

WORKDIR /workspace

COPY docker/worker/entrypoint.sh /usr/local/bin/worker-entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/worker-entrypoint.sh \
 && chmod +x /usr/local/bin/worker-entrypoint.sh

ENV REDIS_URL=redis://redis:6379 \
    JOB_QUEUE=fleet:jobs \
    RESULT_QUEUE=fleet:results \
    CLAUDE_MAX_MINUTES=20 \
    AGENT_MODEL=claude-sonnet-4-7 \
    ACTIVE_PROJECT=example-project

USER fleet

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/worker-entrypoint.sh"]
