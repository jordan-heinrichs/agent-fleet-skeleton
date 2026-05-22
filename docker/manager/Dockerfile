# syntax=docker/dockerfile:1.6
# agent-fleet-skeleton — Manager container.
#
# The manager is bash-only. It does not call claude itself; it orchestrates
# workers. Anthropic spend scales with worker count, not manager time.

FROM node:20-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git \
      openssh-client \
      tini \
      ca-certificates \
      curl \
      jq \
      redis-tools \
 && rm -rf /var/lib/apt/lists/*

# Claude Code CLI is needed for the canary check (lightweight Haiku ping).
RUN npm install -g @anthropic-ai/claude-code@latest

ARG USER_UID=1000
ARG USER_GID=1000
RUN userdel -r node 2>/dev/null || true \
 && groupdel node 2>/dev/null || true \
 && groupadd --gid ${USER_GID} fleet \
 && useradd  --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash fleet

WORKDIR /workspace

COPY docker/manager/entrypoint.sh /usr/local/bin/manager-entrypoint.sh
COPY docker/adapters/ /usr/local/bin/adapters/
# Strip CRLF (Windows autocrlf can convert LF → CRLF and break the shebang).
RUN sed -i 's/\r$//' /usr/local/bin/manager-entrypoint.sh /usr/local/bin/adapters/*.sh \
 && chmod +x /usr/local/bin/manager-entrypoint.sh /usr/local/bin/adapters/*.sh

ENV TICK_INTERVAL_MINUTES=15 \
    FLEET_SIZE=2 \
    REDIS_URL=redis://redis:6379 \
    JOB_QUEUE=fleet:jobs \
    RESULT_QUEUE=fleet:results \
    WORKER_TIMEOUT_MINUTES=25 \
    AGENT_PROVIDER=claude \
    AGENT_FALLBACK= \
    CANARY_MODEL=claude-haiku-4-5-20251001 \
    FALLBACK_CANARY_MODEL=qwen2.5-coder:14b \
    OLLAMA_API_BASE=http://host.docker.internal:11434 \
    ADAPTER_DIR=/usr/local/bin/adapters \
    ACTIVE_PACK=example-research \
    AGENT_AUTO_PUSH=false \
    BRANCH=main \
    GIT_AUTHOR_NAME="fleet manager" \
    GIT_AUTHOR_EMAIL="manager@fleet.local" \
    GIT_COMMITTER_NAME="fleet manager" \
    GIT_COMMITTER_EMAIL="manager@fleet.local"

USER fleet

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/manager-entrypoint.sh"]
