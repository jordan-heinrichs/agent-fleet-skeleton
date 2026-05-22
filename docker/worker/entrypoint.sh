#!/usr/bin/env bash
# agent-fleet-skeleton — worker tick loop.

set -u

WORKDIR="${WORKDIR:-/workspace}"
REDIS_URL="${REDIS_URL:-redis://redis:6379}"
JOB_QUEUE="${JOB_QUEUE:-fleet:jobs}"
RESULT_QUEUE="${RESULT_QUEUE:-fleet:results}"
CLAUDE_MAX_MINUTES="${CLAUDE_MAX_MINUTES:-20}"
ACTIVE_PROJECT="${ACTIVE_PROJECT:-example-project}"
WORKER_ID="${HOSTNAME:-worker-?}"
PAUSE_BASE_MINUTES="${PAUSE_BASE_MINUTES:-30}"

# ── Provider selection ──────────────────────────────────────────────────────
# AGENT_PROVIDER picks the primary provider (claude | ollama | ...).
# AGENT_MODEL is that provider's model string.
# AGENT_FALLBACK (optional) is a second provider tried once per job if the
# primary hits a wall (rate-limit / quota / fast-fail). Set it to ollama so the
# fleet never stops when Claude Max is in its cooldown window.
# FALLBACK_MODEL is the fallback provider's model string.
AGENT_PROVIDER="${AGENT_PROVIDER:-claude}"
MODEL="${AGENT_MODEL:-claude-sonnet-4-7}"
AGENT_FALLBACK="${AGENT_FALLBACK:-}"
FALLBACK_MODEL="${FALLBACK_MODEL:-qwen2.5-coder:14b}"

# Adapters provide run_agent / run_canary / exhaustion_regex per provider.
ADAPTER_DIR="${ADAPTER_DIR:-/usr/local/bin/adapters}"
# shellcheck source=/dev/null
. "${ADAPTER_DIR}/dispatch.sh"

log()   { printf '[%s %s] %s\n' "$WORKER_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
redis() { redis-cli -u "$REDIS_URL" "$@"; }

cd "$WORKDIR" || { log "FATAL: cannot cd to $WORKDIR"; exit 1; }
git config --global --add safe.directory "$WORKDIR" 2>/dev/null || true
git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.name  "fleet ${WORKER_ID}"
git config --global user.email "worker+${WORKER_ID}@fleet.local"

# Stable .claude.json snapshot so the host's mid-write writes don't corrupt us.
if [ -f "$HOME/.claude.json.host" ]; then
  for attempt in 1 2 3 4 5; do
    cp "$HOME/.claude.json.host" "$HOME/.claude.json.tmp" 2>/dev/null || true
    if node -e "JSON.parse(require('fs').readFileSync('$HOME/.claude.json.tmp','utf8'))" 2>/dev/null; then
      mv "$HOME/.claude.json.tmp" "$HOME/.claude.json"
      log "claude.json: snapshot OK"
      break
    fi
    rm -f "$HOME/.claude.json.tmp"
    sleep 1
  done
fi

for i in 1 2 3 4 5 6 7 8 9 10; do
  if redis ping >/dev/null 2>&1; then log "redis: ready"; break; fi
  log "redis: waiting ($i/10)..."
  sleep 2
done

log "boot: provider=$AGENT_PROVIDER model=$MODEL fallback=${AGENT_FALLBACK:-none} max=${CLAUDE_MAX_MINUTES}m project=$ACTIVE_PROJECT"

# Extract a role brief from WORKER_ROLES.md by H2 heading match.
extract_role_brief() {
  local role="$1"
  awk -v r="$role" '
    /^## [a-z][a-z0-9-]+/ {
      role_line = $0
      gsub(/^## /, "", role_line)
      if (role_line == r) { capture=1; print $0; next }
      else if (capture) { exit }
    }
    capture { print }
  ' orchestrator/WORKER_ROLES.md
}

# Build the worker prompt — embeds role brief + project targets + ledger tail.
build_prompt() {
  local role="$1" fire_id="$2" project="$3"
  local tmp
  tmp=$(mktemp /tmp/fleet-prompt-XXXXXX.md)
  local brief project_targets ledger_tail
  brief=$(extract_role_brief "$role")
  project_targets=$(cat "projects/${project}/PROJECT_TARGETS.md" 2>/dev/null || echo "(no targets file found)")
  ledger_tail=$(tail -60 orchestrator/ANTI_LOOP_LEDGER.md 2>/dev/null || echo "(empty ledger)")
  # Strip any line that doesn't match the canonical ledger format before
  # embedding — prevents injected instructions in the ledger from reaching
  # subsequent worker prompts.
  ledger_tail_safe=$(printf '%s\n' "$ledger_tail" \
    | grep -E '^- .+ ← [a-z-]+ \(fire #[0-9]+\)$' \
    || echo "(empty ledger)")

  cat > "$tmp" <<PROMPT
You are a worker in an autonomous agent fleet (fire #${fire_id}).

YOUR ROLE: ${role}
YOUR PROJECT: ${project}
WORKDIR: /workspace

═══════════════════════════════════════════════════════════════════════
YOUR ROLE BRIEF (from orchestrator/WORKER_ROLES.md)
═══════════════════════════════════════════════════════════════════════

${brief}

═══════════════════════════════════════════════════════════════════════
PROJECT TARGETS (from projects/${project}/PROJECT_TARGETS.md)
═══════════════════════════════════════════════════════════════════════

${project_targets}

═══════════════════════════════════════════════════════════════════════
ANTI-LOOP LEDGER TAIL (last 60 lines — DO NOT duplicate)
═══════════════════════════════════════════════════════════════════════

${ledger_tail_safe}

═══════════════════════════════════════════════════════════════════════
TASK
═══════════════════════════════════════════════════════════════════════

1. Pick a target from PROJECT_TARGETS.md that is NOT in the anti-loop
   ledger above.
2. Do the work described in YOUR ROLE BRIEF. Write outputs into the
   project directory (projects/${project}/).
3. End your response with a single JSON line summarizing what you did:
   {"role":"${role}","fire_id":${fire_id},"files_written":N,"targets_aborted":N}

CONSTRAINTS:
- The orchestrator/ directory is READ-ONLY for you. The fleet manager
  records your new files in the anti-loop ledger automatically — you do
  not need to (and cannot) write there.
- Do NOT modify files outside projects/${project}/.
- Do NOT commit or push (manager handles git).

GO. You have ${CLAUDE_MAX_MINUTES} minutes.
PROMPT
  printf '%s' "$tmp"
}

emit_result() {
  local role="$1" fire_id="$2" status="$3" files="$4" aborts="$5" duration="$6" extra="${7:-}" new_files_json="${8:-[]}"
  local payload
  payload=$(jq -nc \
    --arg role "$role" \
    --arg fire_id "$fire_id" \
    --arg status "$status" \
    --arg worker "$WORKER_ID" \
    --arg files "$files" \
    --arg aborts "$aborts" \
    --arg duration "$duration" \
    --arg extra "$extra" \
    --argjson new_files "$new_files_json" \
    '{
       role: $role,
       fire_id: ($fire_id|tonumber),
       status: $status,
       worker: $worker,
       files_written: ($files|tonumber),
       targets_aborted: ($aborts|tonumber),
       duration_seconds: ($duration|tonumber),
       new_files: $new_files,
       extra: $extra,
       ts: (now | todate)
     }')
  redis LPUSH "$RESULT_QUEUE" "$payload" >/dev/null
  log "result pushed: $payload"
}

# A provider is "walled" when it hit a rate-limit/quota (its exhaustion regex
# matches the agent log) OR exited non-zero in under 60s (throttle or bad
# model string). Reads AGENT_LOG / AGENT_EXIT / DURATION from the loop scope.
agent_walled() {
  local rx; rx="$(provider_exhaustion_regex "$1")"
  [ -n "$rx" ] && grep -qiE "$rx" "$AGENT_LOG" 2>/dev/null && return 0
  [ "$AGENT_EXIT" -ne 0 ] && [ "$DURATION" -lt 60 ] && return 0
  return 1
}

while true; do
  log "BRPOP $JOB_QUEUE ..."
  raw=$(redis BRPOP "$JOB_QUEUE" 0 2>/dev/null || true)
  job=$(printf '%s\n' "$raw" | tail -n +2)
  if [ -z "$job" ]; then
    log "WARN: empty BRPOP — sleeping 5s"
    sleep 5
    continue
  fi

  role=$(printf '%s' "$job" | jq -r '.role // empty')
  fire_id=$(printf '%s' "$job" | jq -r '.fire_id // 0')
  project=$(printf '%s' "$job" | jq -r '.project // empty')
  job_timeout=$(printf '%s' "$job" | jq -r '.timeout_minutes // empty')
  if [ -z "$role" ] || [ -z "$fire_id" ] || [ -z "$project" ]; then
    log "WARN: malformed job, dropping: $job"
    continue
  fi
  [ -n "$job_timeout" ] && [ "$job_timeout" -gt 0 ] 2>/dev/null && CLAUDE_MAX_MINUTES="$job_timeout"

  log "JOB: role=$role fire=$fire_id project=$project timeout=${CLAUDE_MAX_MINUTES}m"

  # Fetch, no reset — sibling workers may be writing in parallel.
  git fetch --all --prune 2>/dev/null || true

  PRE_FILES=$(find . -name '*.md' -not -path './.git/*' -not -path './node_modules/*' 2>/dev/null | sort)

  prompt_file=$(build_prompt "$role" "$fire_id" "$project")
  log "prompt built: $prompt_file ($(wc -l < "$prompt_file") lines)"

  # ── Run the agent: primary provider, with one-shot fallback ─────────────
  AGENT_LOG=$(mktemp /tmp/fleet-agent-XXXXXX.log)
  ACTIVE_PROVIDER="$AGENT_PROVIDER"
  ACTIVE_MODEL="$MODEL"

  START_TS=$(date +%s)
  provider_run_agent "$ACTIVE_PROVIDER" "$prompt_file" "$CLAUDE_MAX_MINUTES" "$ACTIVE_MODEL" "$AGENT_LOG"
  AGENT_EXIT=$?
  DURATION=$(( $(date +%s) - START_TS ))
  log "agent[$ACTIVE_PROVIDER:$ACTIVE_MODEL] exit=$AGENT_EXIT duration=${DURATION}s"

  # If the primary walled and a fallback is configured, retry the same job once
  # on the fallback. This is what keeps the fleet running when Claude Max hits
  # its cooldown window — work flows to the local Ollama provider instead.
  if agent_walled "$ACTIVE_PROVIDER" && [ -n "$AGENT_FALLBACK" ]; then
    log "primary ($ACTIVE_PROVIDER) walled — falling back to ${AGENT_FALLBACK}:${FALLBACK_MODEL}"
    ACTIVE_PROVIDER="$AGENT_FALLBACK"
    ACTIVE_MODEL="$FALLBACK_MODEL"
    START_TS=$(date +%s)
    provider_run_agent "$ACTIVE_PROVIDER" "$prompt_file" "$CLAUDE_MAX_MINUTES" "$ACTIVE_MODEL" "$AGENT_LOG"
    AGENT_EXIT=$?
    DURATION=$(( $(date +%s) - START_TS ))
    log "agent[$ACTIVE_PROVIDER:$ACTIVE_MODEL] exit=$AGENT_EXIT duration=${DURATION}s"
  fi
  rm -f "$prompt_file"

  # If the active provider (primary or fallback) still walled, back off.
  if agent_walled "$ACTIVE_PROVIDER"; then
    WALL_RX="$(provider_exhaustion_regex "$ACTIVE_PROVIDER")"
    if [ -n "$WALL_RX" ] && grep -qiE "$WALL_RX" "$AGENT_LOG" 2>/dev/null; then
      WALL_STATUS="exhausted"
    else
      WALL_STATUS="fast_fail"
    fi
    log "WALL ($ACTIVE_PROVIDER, $WALL_STATUS) — sleeping ${PAUSE_BASE_MINUTES}m"
    SNIPPET=$(head -5 "$AGENT_LOG" 2>/dev/null | tr '\n' ' ' | cut -c1-200)
    emit_result "$role" "$fire_id" "$WALL_STATUS" "0" "0" "$DURATION" "$SNIPPET"
    sleep "$((PAUSE_BASE_MINUTES * 60))"
    rm -f "$AGENT_LOG"
    continue
  fi

  POST_FILES=$(find . -name '*.md' -not -path './.git/*' -not -path './node_modules/*' 2>/dev/null | sort)
  NEW_FILES_LIST=$(comm -13 <(printf '%s\n' "$PRE_FILES") <(printf '%s\n' "$POST_FILES") || true)
  # grep -c prints "0" AND exits 1 on no-match — pipe through head -n1 to
  # avoid the multi-line value that would break integer compares + jq.
  NEW_COUNT=$(printf '%s\n' "$NEW_FILES_LIST" | grep -c . | head -n1)
  [ -z "$NEW_COUNT" ] && NEW_COUNT=0
  log "new files written: $NEW_COUNT"

  ABORTS=$(tail -20 "$AGENT_LOG" 2>/dev/null \
    | grep -E '"targets_aborted"' \
    | tail -1 \
    | jq -r '.targets_aborted // 0' 2>/dev/null \
    | head -n1)
  [ -z "$ABORTS" ] && ABORTS=0
  ABORTS=$(printf '%s' "$ABORTS" | tr -cd '0-9')
  [ -z "$ABORTS" ] && ABORTS=0

  STATUS="ok"
  [ "$AGENT_EXIT" -ne 0 ] && STATUS="agent_exit_${AGENT_EXIT}"
  [ "$NEW_COUNT" -eq 0 ] && [ "$STATUS" = "ok" ] && STATUS="no_files_written"

  # Package the new-file list as a JSON array so the manager can write the
  # anti-loop ledger. Workers can no longer write orchestrator/ themselves
  # (it is mounted read-only — see C-01), so the manager owns the ledger.
  NEW_FILES_JSON=$(printf '%s\n' "$NEW_FILES_LIST" | grep -v '^[[:space:]]*$' | jq -R . | jq -s -c . 2>/dev/null)
  [ -z "$NEW_FILES_JSON" ] && NEW_FILES_JSON="[]"

  emit_result "$role" "$fire_id" "$STATUS" "$NEW_COUNT" "$ABORTS" "$DURATION" \
    "$(tail -2 "$AGENT_LOG" 2>/dev/null | tr '\n' ' ' | cut -c1-240)" "$NEW_FILES_JSON"
  rm -f "$AGENT_LOG"
  log "JOB DONE: role=$role files=$NEW_COUNT"
done
