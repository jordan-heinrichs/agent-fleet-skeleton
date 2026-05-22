#!/usr/bin/env bash
# Provider adapter: Ollama (local models) driven by Aider.
#
# Ollama is a model server, not an agent — it returns text but cannot write
# files or use tools on its own. Aider is the agentic wrapper that drives it.
# Ollama runs on the HOST; the container reaches it at OLLAMA_API_BASE
# (default http://host.docker.internal:11434, which Docker Desktop maps to the
# host automatically).
#
# Cost: $0. No subscription, no API key, no rate-limit window. Quality and
# speed depend entirely on the host hardware and the model you pull. This is
# the "runs forever for free" path and the natural fallback for when a
# subscription provider hits its usage ceiling.
#
# Setup on the host (one time):
#   1. install Ollama (https://ollama.com)
#   2. ollama pull qwen2.5-coder:14b   (or whatever model you set as AGENT_MODEL)

OLLAMA_EXHAUSTION_REGEX='connection refused|could not connect|failed to (establish a )?connect|ECONNREFUSED|connection error|model ".*" not found|no such model|pull the model|out of memory|CUDA error|context deadline exceeded|cannot reach|max retries exceeded'

ollama_exhaustion_regex() { printf '%s' "$OLLAMA_EXHAUSTION_REGEX"; }

ollama_run_agent() {
  local prompt_file="$1" timeout_min="$2" model="$3" log_file="$4"
  export OLLAMA_API_BASE="${OLLAMA_API_BASE:-http://host.docker.internal:11434}"
  # Aider one-shot: run the message, write files, exit. The manager owns git,
  # so auto-commits are disabled here. Repo map is capped small to keep the
  # context budget sane for local models.
  timeout "${timeout_min}m" aider \
    --model "ollama_chat/${model}" \
    --yes \
    --no-auto-commits \
    --no-check-update \
    --no-show-model-warnings \
    --map-tokens 512 \
    --message "$(cat "$prompt_file")" \
    > "$log_file" 2>&1
}

ollama_run_canary() {
  local model="$1" log_file="$2"
  local base="${OLLAMA_API_BASE:-http://host.docker.internal:11434}"
  # Direct hit on the Ollama API — verifies the server is reachable AND the
  # model is loadable, for the price of one tiny generation.
  curl -fsS -m 90 "${base}/api/generate" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"${model}\",\"prompt\":\"respond with OK\",\"stream\":false}" \
    > "$log_file" 2>&1
}
