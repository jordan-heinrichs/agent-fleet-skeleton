# syntax=docker/dockerfile:1.6
# agent-fleet-skeleton — Worker container.
#
# Stateless. BRPOP a job, run an agent (Claude or Ollama) with the role brief,
# push result. Multiple worker containers run in parallel via deploy.replicas.

FROM node:20-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git \
      tini \
      ca-certificates \
      curl \
      jq \
      redis-tools \
      python3 \
      python3-venv \
      pipx \
 && rm -rf /var/lib/apt/lists/*

# Claude provider — the Claude Code CLI.
RUN npm install -g @anthropic-ai/claude-code@latest

# Ollama provider — Aider is the agentic wrapper that drives local Ollama
# models. Installed globally via pipx so `aider` is on PATH for the fleet user.
# (Only used when AGENT_PROVIDER=ollama or AGENT_FALLBACK=ollama.)
ENV PIPX_HOME=/opt/pipx \
    PIPX_BIN_DIR=/usr/local/bin
RUN pipx install aider-chat \
 && pipx ensurepath || true

ARG USER_UID=1000
ARG USER_GID=1000
RUN userdel -r node 2>/dev/null || true \
 && groupdel node 2>/dev/null || true \
 && groupadd --gid ${USER_GID} fleet \
 && useradd  --uid ${USER_UID} --gid ${USER_GID} --create-home --shell /bin/bash fleet

WORKDIR /workspace

COPY docker/worker/entrypoint.sh /usr/local/bin/worker-entrypoint.sh
COPY docker/adapters/ /usr/local/bin/adapters/
RUN sed -i 's/\r$//' /usr/local/bin/worker-entrypoint.sh /usr/local/bin/adapters/*.sh \
 && chmod +x /usr/local/bin/worker-entrypoint.sh /usr/local/bin/adapters/*.sh

ENV REDIS_URL=redis://redis:6379 \
    JOB_QUEUE=fleet:jobs \
    RESULT_QUEUE=fleet:results \
    CLAUDE_MAX_MINUTES=20 \
    AGENT_PROVIDER=claude \
    AGENT_MODEL=claude-sonnet-4-7 \
    AGENT_FALLBACK= \
    FALLBACK_MODEL=qwen2.5-coder:14b \
    OLLAMA_API_BASE=http://host.docker.internal:11434 \
    ADAPTER_DIR=/usr/local/bin/adapters \
    ACTIVE_PROJECT=example-project

USER fleet

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/worker-entrypoint.sh"]
