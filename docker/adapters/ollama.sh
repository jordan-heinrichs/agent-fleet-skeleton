#!/usr/bin/env bash
# Provider adapter: Ollama (local models) — direct generation.
#
# Ollama is a model server: it returns text but cannot write files or use tools.
# This adapter used to drive the model through Aider, but Aider's edit protocol
# is unreliable with smaller local models — they tend to reply in chat instead
# of emitting file edits, so no deliverable lands (and Aider's chat-history
# scratch file masquerades as "output"). For the pack model — each role writes
# ONE markdown document — direct generation is both simpler and far more
# reliable: we POST the prompt to Ollama, take the text back, and write it to the
# role's output file ourselves.
#
# The worker builds a direct-generation prompt for this provider (the model's
# entire response IS the document) and tells us where to write it via
# FLEET_OUT_FILE, exported per job.
#
# Ollama runs on the HOST; the container reaches it at OLLAMA_API_BASE
# (default http://host.docker.internal:11434, which Docker Desktop maps to the
# host automatically).
#
# Cost: $0. No subscription, no API key, no rate-limit window. Quality and speed
# depend entirely on the host hardware and the model you pull. This is the "runs
# forever for free" path and the natural fallback for when a subscription
# provider hits its usage ceiling.
#
# Setup on the host (one time):
#   1. install Ollama (https://ollama.com)
#   2. ollama pull qwen2.5-coder:14b   (or whatever model you set as AGENT_MODEL)

OLLAMA_EXHAUSTION_REGEX='connection refused|could not connect|failed to (establish a )?connect|ECONNREFUSED|connection error|model ".*" not found|no such model|pull the model|out of memory|CUDA error|context deadline exceeded|cannot reach|max retries exceeded'

ollama_exhaustion_regex() { printf '%s' "$OLLAMA_EXHAUSTION_REGEX"; }

ollama_run_agent() {
  local prompt_file="$1" timeout_min="$2" model="$3" log_file="$4"
  local base="${OLLAMA_API_BASE:-http://host.docker.internal:11434}"
  local out_file="${FLEET_OUT_FILE:-}"
  local num_ctx="${OLLAMA_NUM_CTX:-16384}"
  local num_predict="${OLLAMA_NUM_PREDICT:-4096}"
  local secs=$(( timeout_min * 60 )); [ "$secs" -lt 60 ] && secs=60

  # Build the request with jq so the prompt (quotes, newlines, code) is escaped
  # correctly. think:false silences qwen3-style reasoning models; it is ignored
  # by models that do not reason, so it is safe to always send.
  local req
  req=$(jq -nc \
    --arg model "$model" \
    --rawfile prompt "$prompt_file" \
    --argjson num_ctx "$num_ctx" \
    --argjson num_predict "$num_predict" \
    '{model:$model, prompt:$prompt, stream:false, think:false,
      options:{temperature:0.4, num_ctx:$num_ctx, num_predict:$num_predict}}')

  # One direct generation. Raw curl errors + JSON body go to the log so the
  # worker's wall/exhaustion detection can read them.
  local resp rc respf
  resp=$(curl -fsS -m "$secs" "${base}/api/generate" \
           -H 'content-type: application/json' --data-binary "$req" 2>"$log_file")
  rc=$?
  printf '%s\n' "$resp" >> "$log_file"
  [ "$rc" -ne 0 ] && return "$rc"

  # Extract the deliverable. We parse in Python (via a temp file, to dodge any
  # argv/stdin size limits) so the cleanup is robust:
  #   - take .response from the API JSON
  #   - drop a <think>…</think> reasoning preamble (qwen3)
  #   - unwrap a whole-response ```json / ```markdown fence ONLY — a real code
  #     fence like ```solidity is part of the document and is left untouched
  #   - strip stray JSON accounting lines the model may have emitted
  respf=$(mktemp /tmp/ollama-resp-XXXXXX.json)
  printf '%s' "$resp" > "$respf"
  local text
  text=$(python3 -c '
import sys, json, re
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
try:
    t = json.loads(raw).get("response", "")
except Exception:
    t = raw
if "</think>" in t:
    t = t.split("</think>")[-1]
lines = t.split("\n")
while lines and not lines[0].strip(): lines.pop(0)
while lines and not lines[-1].strip(): lines.pop()
if lines and re.match(r"^```(json|markdown|md)\s*$", lines[0].strip(), re.I) and lines[-1].strip() == "```":
    lines = lines[1:-1]
lines = [ln for ln in lines if not re.match(r"^\s*\{.*\"files_written\".*\}\s*$", ln)]
while lines and not lines[0].strip(): lines.pop(0)
while lines and not lines[-1].strip(): lines.pop()
sys.stdout.write("\n".join(lines))
' "$respf")
  rm -f "$respf"

  if [ -z "${text//[[:space:]]/}" ]; then
    echo "ollama: model returned no usable document (JSON-only or empty)" >> "$log_file"
    return 1
  fi

  if [ -n "$out_file" ]; then
    mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
    printf '%s\n' "$text" > "$out_file"
    echo "ollama: wrote $(printf '%s\n' "$text" | wc -l) lines -> $out_file" >> "$log_file"
  else
    # No target supplied (non-pack use) — at least surface the text in the log.
    printf '%s\n' "$text" >> "$log_file"
  fi
  return 0
}

ollama_run_canary() {
  local model="$1" log_file="$2"
  local base="${OLLAMA_API_BASE:-http://host.docker.internal:11434}"
  # Direct hit on the Ollama API — verifies the server is reachable AND the
  # model is loadable, for the price of one tiny generation.
  curl -fsS -m 90 "${base}/api/generate" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"${model}\",\"prompt\":\"respond with OK\",\"stream\":false,\"think\":false}" \
    > "$log_file" 2>&1
}
