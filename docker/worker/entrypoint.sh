#!/usr/bin/env bash
# agent-fleet-skeleton — worker tick loop.

set -u

WORKDIR="${WORKDIR:-/workspace}"
REDIS_URL="${REDIS_URL:-redis://redis:6379}"
JOB_QUEUE="${JOB_QUEUE:-fleet:jobs}"
RESULT_QUEUE="${RESULT_QUEUE:-fleet:results}"
CLAUDE_MAX_MINUTES="${CLAUDE_MAX_MINUTES:-20}"
WORKER_ID="${HOSTNAME:-worker-?}"
PAUSE_BASE_MINUTES="${PAUSE_BASE_MINUTES:-30}"

# ── Active pack (the topic plugin) ───────────────────────────────────────────
# A pack is a self-contained domain: packs/<name>/{pack.env,ROLES.md,TARGETS.md}.
# Swap ACTIVE_PACK to retarget the whole fleet without touching the engine.
ACTIVE_PACK="${ACTIVE_PACK:-example-research}"
PACK_DIR="packs/${ACTIVE_PACK}"
# Pack defaults — overridden by the pack's pack.env (sourced after cd below).
PACK_NAME="$ACTIVE_PACK"
WEB_GROUNDING="false"
OUTPUT_DIR="output"
SEARCH_PREFERRED_DOMAINS=""
SEARCH_BLOCK_DOMAINS=""

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

# Load the active pack's config (web grounding, output dir, search prefs).
if [ -f "${PACK_DIR}/pack.env" ]; then
  # shellcheck source=/dev/null
  . "${PACK_DIR}/pack.env"
fi
export SEARCH_PREFERRED_DOMAINS SEARCH_BLOCK_DOMAINS

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

log "boot: pack=$ACTIVE_PACK provider=$AGENT_PROVIDER model=$MODEL fallback=${AGENT_FALLBACK:-none} grounding=$WEB_GROUNDING max=${CLAUDE_MAX_MINUTES}m"

# H-03: Copy ~/.claude to a per-worker private directory so concurrent workers
# don't collide on OAuth token refresh writes to the shared bind-mounted dir.
WORKER_CLAUDE_HOME="/tmp/claude-${WORKER_ID}"
mkdir -p "$WORKER_CLAUDE_HOME/.claude"
cp -r "$HOME/.claude/." "$WORKER_CLAUDE_HOME/.claude/" 2>/dev/null || true
[ -f "$HOME/.claude.json" ] && cp "$HOME/.claude.json" "$WORKER_CLAUDE_HOME/.claude.json" 2>/dev/null || true
log "claude home: private copy at $WORKER_CLAUDE_HOME"

# Extract a role's full section from the active pack's ROLES.md (H2 match).
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
  ' "${PACK_DIR}/ROLES.md"
}

# Per-role machine-read fields from the role's section.
role_field() {  # role field-label
  extract_role_brief "$1" | grep -m1 -iE "^\\*\\*${2}:\\*\\*" | sed -E "s/^\\*\\*${2}:\\*\\*[[:space:]]*//I"
}
role_search() { role_field "$1" "Search"; }
role_output() {
  local o; o=$(role_field "$1" "Output")
  [ -z "$o" ] && o="$1"            # default subdir = role name
  printf '%s' "$o"
}

# Best-effort exact deliverable path: the first `output/.../*.md` path named in
# the role brief, else <output>/<sub>/<role>.md so a file always lands even when
# the pack doesn't name one. Used by file-writing providers (Ollama direct-gen);
# strong agents (Claude) pick their own filename and ignore this.
role_outfile() {  # role
  local role="$1" sub f
  sub=$(role_output "$role")
  f=$(extract_role_brief "$role" \
        | grep -oE "${OUTPUT_DIR}/[A-Za-z0-9_./-]+\.md" \
        | head -n1)
  if [ -n "$f" ]; then
    printf '%s/%s' "$PACK_DIR" "$f"
  else
    printf '%s/%s/%s/%s.md' "$PACK_DIR" "$OUTPUT_DIR" "$sub" "$role"
  fi
}

# Build the worker prompt — role brief + pack targets + ledger + (optional)
# live web sources from the cached research step.
build_prompt() {
  local role="$1" fire_id="$2" provider="${3:-$AGENT_PROVIDER}"
  local tmp brief targets ledger_tail out_sub out_file web_context query
  tmp=$(mktemp /tmp/fleet-prompt-XXXXXX.md)
  brief=$(extract_role_brief "$role")
  targets=$(cat "${PACK_DIR}/TARGETS.md" 2>/dev/null || echo "(no TARGETS.md in pack)")
  out_sub=$(role_output "$role")
  out_file=$(role_outfile "$role")
  ledger_tail=$(tail -80 orchestrator/ANTI_LOOP_LEDGER.md 2>/dev/null \
    | grep -E '^- .+ ← [a-z-]+ \(fire #[0-9]+\)$' || echo "(empty ledger)")

  # Optional web grounding: fetch real sources for the role's search query.
  web_context=""
  if [ "$WEB_GROUNDING" = "true" ]; then
    query=$(role_search "$role"); [ -z "$query" ] && query="$role research 2025"
    log "research: '$query' (grounding on, cache active)"
    web_context=$(timeout 150 python3 /usr/local/bin/research.py "$query" "${RESEARCH_RESULTS:-6}" 2>/dev/null)
    [ -z "$web_context" ] && web_context="(web research returned nothing — do not invent sources)"
    web_context="═══════════════════════════════════════════════════════════════════════
LIVE WEB SOURCES (real, fetched just now — cite ONLY these URLs)
═══════════════════════════════════════════════════════════════════════

${web_context}
"
  fi

  # Shared context block — identical for every provider.
  cat > "$tmp" <<PROMPT
You are a worker in an autonomous agent fleet (fire #${fire_id}).
Pack: ${PACK_NAME}.  Role: ${role}.  WORKDIR: /workspace

═══════════════════════════════════════════════════════════════════════
YOUR ROLE BRIEF (from ${PACK_DIR}/ROLES.md)
═══════════════════════════════════════════════════════════════════════

${brief}

${web_context}═══════════════════════════════════════════════════════════════════════
TARGETS (from ${PACK_DIR}/TARGETS.md)
═══════════════════════════════════════════════════════════════════════

${targets}

═══════════════════════════════════════════════════════════════════════
ALREADY COVERED — prefer something new
═══════════════════════════════════════════════════════════════════════

${ledger_tail}
PROMPT

  # Provider-specific task section.
  #  • Agentic providers (claude) use tools to write files, then report a JSON
  #    accounting line. Unchanged from the original contract.
  #  • Direct-generation providers (ollama) cannot use tools — their entire text
  #    response IS the deliverable, so we ask for the document itself and
  #    nothing else. Asking such a model for "files + JSON" makes it emit only
  #    the JSON and skip the document, which is exactly what we must avoid.
  if [ "$provider" = "ollama" ]; then
    cat >> "$tmp" <<PROMPT

═══════════════════════════════════════════════════════════════════════
TASK — write the document
═══════════════════════════════════════════════════════════════════════

Do the work described in YOUR ROLE BRIEF. ${WEB_GROUNDING:+Use ONLY facts and URLs from the LIVE WEB SOURCES above; do not invent sources. }Prefer a target not in the ALREADY COVERED list; if everything is covered, DEEPEN the document instead. Never refuse and never return an empty or JSON-only response.

OUTPUT RULES — strict:
- Your ENTIRE response becomes this one file: ${out_file}
- Output ONLY the document, in GitHub-flavored Markdown, beginning immediately
  with a "# " title line.
- Meet your role brief's quality bar (length, depth, concreteness).
- Do NOT output JSON, status lines, file paths, apologies, or any commentary
  before or after the document.
- Do NOT wrap the whole document in a code fence. Fenced code blocks INSIDE the
  document (for example \`\`\`solidity) are expected where relevant.

Begin the document now.
PROMPT
  else
    cat >> "$tmp" <<PROMPT

═══════════════════════════════════════════════════════════════════════
TASK
═══════════════════════════════════════════════════════════════════════

1. Pick a specific target NOT in the "already covered" list.
2. Do the work in YOUR ROLE BRIEF. ${WEB_GROUNDING:+Use ONLY facts and URLs from the LIVE WEB SOURCES above; do not invent sources.}
3. Write your output file(s) under: ${PACK_DIR}/${OUTPUT_DIR}/${out_sub}/
4. End your response with one JSON line:
   {"role":"${role}","fire_id":${fire_id},"files_written":N,"targets_aborted":N}

CONSTRAINTS:
- orchestrator/ is READ-ONLY. The manager records the anti-loop ledger; you
  do not (and cannot) write there.
- Write only under ${PACK_DIR}/${OUTPUT_DIR}/.
- Do NOT commit or push (manager handles git).

GO. You have ${CLAUDE_MAX_MINUTES} minutes.
PROMPT
  fi
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
  redis LPUSH "${RESULT_QUEUE}:fire-${fire_id}" "$payload" >/dev/null
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
  log "waiting for job..."
  # H-02: BLMOVE atomically moves the job into a processing list. If this
  # worker crashes mid-run, the job stays in fleet:jobs-processing and gets
  # requeued by the manager on next boot rather than being silently lost.
  job=$(redis BLMOVE "$JOB_QUEUE" "${JOB_QUEUE}-processing" RIGHT LEFT 0 2>/dev/null || true)
  if [ -z "$job" ]; then
    log "WARN: empty BLMOVE — sleeping 5s"
    sleep 5
    continue
  fi

  role=$(printf '%s' "$job" | jq -r '.role // empty')
  fire_id=$(printf '%s' "$job" | jq -r '.fire_id // 0')
  job_timeout=$(printf '%s' "$job" | jq -r '.timeout_minutes // empty')
  if [ -z "$role" ] || [ -z "$fire_id" ]; then
    log "WARN: malformed job, dropping: $job"
    redis LREM "${JOB_QUEUE}-processing" 1 "$job" >/dev/null 2>&1 || true
    continue
  fi
  [ -n "$job_timeout" ] && [ "$job_timeout" -gt 0 ] 2>/dev/null && CLAUDE_MAX_MINUTES="$job_timeout"

  log "JOB: role=$role fire=$fire_id pack=$ACTIVE_PACK timeout=${CLAUDE_MAX_MINUTES}m"

  # Fetch, no reset — sibling workers may be writing in parallel.
  git fetch --all --prune 2>/dev/null || true
  mkdir -p "${PACK_DIR}/${OUTPUT_DIR}/$(role_output "$role")" 2>/dev/null || true

  # Scope new-file detection to the pack's output dir only. Counting the whole
  # repo would pick up provider scratch files (e.g. aider's chat history) and
  # report them as deliverables — a false positive that hides a real failure.
  PRE_FILES=$(find "${PACK_DIR}/${OUTPUT_DIR}" -name '*.md' 2>/dev/null | sort)

  prompt_file=$(build_prompt "$role" "$fire_id" "$AGENT_PROVIDER")
  log "prompt built: $prompt_file ($(wc -l < "$prompt_file") lines)"

  # ── Run the agent: primary provider, with one-shot fallback ─────────────
  AGENT_LOG=$(mktemp /tmp/fleet-agent-XXXXXX.log)
  ACTIVE_PROVIDER="$AGENT_PROVIDER"
  ACTIVE_MODEL="$MODEL"

  # Tell file-writing providers (Ollama direct-gen) exactly where the deliverable
  # goes. Strong agents (Claude) write files themselves and ignore this.
  export FLEET_OUT_FILE="$(role_outfile "$role")"

  # H-03: run agent with the per-worker private Claude home so concurrent workers
  # don't race on OAuth token refreshes to the shared bind-mounted ~/.claude.

  START_TS=$(date +%s)
  HOME="$WORKER_CLAUDE_HOME" provider_run_agent "$ACTIVE_PROVIDER" "$prompt_file" "$CLAUDE_MAX_MINUTES" "$ACTIVE_MODEL" "$AGENT_LOG"
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
    # Rebuild the prompt for the fallback provider's mode (agentic vs direct-gen).
    rm -f "$prompt_file"; prompt_file=$(build_prompt "$role" "$fire_id" "$ACTIVE_PROVIDER")
    START_TS=$(date +%s)
    HOME="$WORKER_CLAUDE_HOME" provider_run_agent "$ACTIVE_PROVIDER" "$prompt_file" "$CLAUDE_MAX_MINUTES" "$ACTIVE_MODEL" "$AGENT_LOG"
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
    redis LREM "${JOB_QUEUE}-processing" 1 "$job" >/dev/null 2>&1 || true
    continue
  fi

  POST_FILES=$(find "${PACK_DIR}/${OUTPUT_DIR}" -name '*.md' 2>/dev/null | sort)
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
  redis LREM "${JOB_QUEUE}-processing" 1 "$job" >/dev/null 2>&1 || true
  log "JOB DONE: role=$role files=$NEW_COUNT"
done
