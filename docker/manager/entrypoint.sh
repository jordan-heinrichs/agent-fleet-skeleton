#!/usr/bin/env bash
# agent-fleet-skeleton — manager tick loop.
#
# Per tick:
#   1. canary check (Haiku ping) — verify auth + credits before spending tokens
#   2. pick FLEET_SIZE roles deterministically (lowest-count-first in ledger)
#   3. LPUSH N jobs to Redis
#   4. BRPOP N results (with timeout grace)
#   5. supervisor pass — flag stuck:zero_files if no work landed
#   6. commit + optional push
#   7. sleep until next tick

set -u

WORKDIR="${WORKDIR:-/workspace}"
TICK_INTERVAL_MINUTES="${TICK_INTERVAL_MINUTES:-15}"
FLEET_SIZE="${FLEET_SIZE:-2}"
REDIS_URL="${REDIS_URL:-redis://redis:6379}"
JOB_QUEUE="${JOB_QUEUE:-fleet:jobs}"
RESULT_QUEUE="${RESULT_QUEUE:-fleet:results}"
WORKER_TIMEOUT_MINUTES="${WORKER_TIMEOUT_MINUTES:-25}"
CANARY_MODEL="${CANARY_MODEL:-claude-haiku-4-5-20251001}"
ACTIVE_PROJECT="${ACTIVE_PROJECT:-example-project}"
BRANCH="${BRANCH:-main}"
AUTO_PUSH="${AGENT_AUTO_PUSH:-false}"
ORCH_DIR="orchestrator"
LEDGER_FILE="${ORCH_DIR}/ANTI_LOOP_LEDGER.md"
NORTH_STAR_FILE="${ORCH_DIR}/NORTH_STAR.json"
SUPERVISOR_LOG="${ORCH_DIR}/SUPERVISOR_LOG.jsonl"
STUCK_FILE="${ORCH_DIR}/STUCK.md"
PAUSE_BASE_MINUTES="${PAUSE_BASE_MINUTES:-30}"

# Exhaustion regex — tightly anchored to Anthropic API context so generic
# words like "rate limit" in project content can't false-positive.
EXHAUSTION_REGEX='anthropic[^"]{0,40}(rate.?limit|quota|insufficient|credit|billing)|claude[-_]?(api|code)[^"]{0,40}(rate.?limit|quota|insufficient|credit|billing)|"type"[^"]*"(rate_limit_error|overloaded_error|authentication_error|permission_error|insufficient_credit|billing_error)"|HTTP\/[12](\.[01])?[[:space:]]+429[^0-9]|status[[:space:]]+(code[[:space:]]+)?429[^0-9]|insufficient_balance|credit balance (too low|exhausted|depleted)|max[-_ ]?plan.{0,40}(limit|exceeded|expired)|exceeded your (monthly|daily|current) quota'

# Logs to STDERR so functions used inside $(...) don't pollute captured stdout.
log()    { printf '[manager %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
banner() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$1" >&2; }
redis()  { redis-cli -u "$REDIS_URL" "$@"; }

cd "$WORKDIR" || { log "FATAL: cannot cd to $WORKDIR"; exit 1; }

# Allow git inside the bind-mounted volume.
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig-fleet"
touch "$GIT_CONFIG_GLOBAL" 2>/dev/null || true
git config --global --add safe.directory "$WORKDIR" 2>/dev/null || true
git config --global --add safe.directory '*'        2>/dev/null || true
git config --global user.name  "${GIT_AUTHOR_NAME:-fleet manager}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-manager@fleet.local}"

log "boot: tick=${TICK_INTERVAL_MINUTES}m size=$FLEET_SIZE redis=$REDIS_URL project=$ACTIVE_PROJECT"

# SSH key perm fix — Windows bind mounts come through 0755 which OpenSSH rejects.
if [ -d "$HOME/.ssh" ]; then
  mkdir -p "$HOME/.ssh-writable"
  cp -r "$HOME"/.ssh/. "$HOME/.ssh-writable/" 2>/dev/null || true
  chmod 700 "$HOME/.ssh-writable" 2>/dev/null || true
  find "$HOME/.ssh-writable" -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} \; 2>/dev/null || true
  find "$HOME/.ssh-writable" -type f \( -name '*.pub' -o -name 'known_hosts*' -o -name 'config' \) -exec chmod 644 {} \; 2>/dev/null || true
  export GIT_SSH_COMMAND="ssh -i $HOME/.ssh-writable/id_rsa -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh-writable/known_hosts"
fi

# Stable .claude.json snapshot — host writes constantly to its own copy.
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

# Wait for Redis.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if redis ping >/dev/null 2>&1; then log "redis: ready"; break; fi
  log "redis: waiting ($i/10)..."
  sleep 2
done

mkdir -p "$ORCH_DIR/WORKER_REPORTS"

# H-02: On boot, move any jobs left in the processing queue by a previous crash
# back into the job queue so they get retried this session.
orphaned=$(redis LLEN "${JOB_QUEUE}-processing" 2>/dev/null || echo 0)
if [ "${orphaned:-0}" -gt 0 ] 2>/dev/null; then
  for _i in $(seq 1 "$orphaned"); do
    redis LMOVE "${JOB_QUEUE}-processing" "$JOB_QUEUE" LEFT RIGHT >/dev/null 2>&1 || true
  done
  log "requeued $orphaned orphaned job(s) from previous crash"
fi

# Discover roles from WORKER_ROLES.md. Each role section starts with `## <name>`.
discover_roles() {
  grep -oE '^## [a-z][a-z0-9-]+' "${ORCH_DIR}/WORKER_ROLES.md" 2>/dev/null \
    | sed -E 's/^## //'
}

# Pick FLEET_SIZE roles, biased toward those with the lowest count in the ledger.
pick_roles() {
  local n="$1"
  local role count
  declare -A counts
  mapfile -t ROLES < <(discover_roles)
  if [ "${#ROLES[@]}" -eq 0 ]; then
    log "WARN: no roles found in ${ORCH_DIR}/WORKER_ROLES.md"
    return 1
  fi
  for role in "${ROLES[@]}"; do
    count=$(grep -cE "← $role" "$LEDGER_FILE" 2>/dev/null | head -n1)
    [ -z "$count" ] && count=0
    counts["$role"]=$count
  done
  for role in "${ROLES[@]}"; do
    printf '%s\t%s\n' "${counts[$role]}" "$role"
  done | sort -n -k1,1 | head -"$n" | awk '{print $2}'
}

build_job_json() {
  local fire_id="$1" role="$2" timeout_min="$3"
  jq -nc \
    --arg fire_id "$fire_id" \
    --arg role "$role" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg timeout "$timeout_min" \
    --arg project "$ACTIVE_PROJECT" \
    '{fire_id: ($fire_id|tonumber), role: $role, project: $project, dispatched_at: $ts, timeout_minutes: ($timeout|tonumber)}'
}

# Canary — verify Claude auth + credits with a cheap Haiku call before the fire.
canary_check() {
  local tick="$1"
  local canary_log="${ORCH_DIR}/last-canary.log"
  log "canary: pinging $CANARY_MODEL (2m timeout)..."
  timeout 2m claude --dangerously-skip-permissions --model "$CANARY_MODEL" --print "respond with OK" \
    > "$canary_log" 2>&1
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    log "canary FAILED: exit=$exit_code (see $canary_log)"
    return 1
  fi
  if grep -qiE "$EXHAUSTION_REGEX" "$canary_log" 2>/dev/null; then
    log "canary: exhaustion signal in response"
    return 1
  fi
  log "canary: OK"
  return 0
}

# Backoff helper.
pause_on_exhaustion() {
  local reason="$1"
  log "PAUSE on '$reason' — sleeping ${PAUSE_BASE_MINUTES}m"
  sleep "$((PAUSE_BASE_MINUTES * 60))"
}

# Stuck detection — 3 consecutive zero-file fires writes STUCK.md.
check_stuck() {
  local zero_fires
  zero_fires=$(tail -3 "$SUPERVISOR_LOG" 2>/dev/null \
    | jq -s 'map(select(.files_written_total == 0)) | length' 2>/dev/null || echo 0)
  [ "${zero_fires:-0}" -ge 3 ]
}

write_stuck_marker() {
  local fire_id="$1"
  cat > "$STUCK_FILE" <<MARKER
# Fleet STUCK at fire #${fire_id}

**Detected at:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Reason:** 3 consecutive zero-file fires

## Last 3 supervisor entries
\`\`\`
$(tail -3 "$SUPERVISOR_LOG" 2>/dev/null)
\`\`\`

## How to resume

1. Inspect SUPERVISOR_LOG.jsonl and WORKER_REPORTS/.
2. \`rm $STUCK_FILE\` to resume the loop.
MARKER
  log "supervisor: wrote $STUCK_FILE"
}

append_supervisor() {
  local fire_id="$1" decision="$2" files_total="$3"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","fire_id":%d,"fleet_size":%d,"files_written_total":%d,"decision":"%s"}\n' \
    "$ts" "$fire_id" "$FLEET_SIZE" "$files_total" "$decision" >> "$SUPERVISOR_LOG"
}

# ─── Main loop ───────────────────────────────────────────────────────────────
fire_id=0
while true; do
  fire_id=$((fire_id + 1))
  banner "FIRE #${fire_id} START"

  # STUCK halt check.
  if [ -f "$STUCK_FILE" ]; then
    log "STUCK marker present — sleeping ${TICK_INTERVAL_MINUTES}m. Remove $STUCK_FILE to resume."
    sleep "$((TICK_INTERVAL_MINUTES * 60))"
    continue
  fi

  # 1. Canary
  if ! canary_check "$fire_id"; then
    pause_on_exhaustion "canary_failed"
    continue
  fi

  # 2. Pick roles
  banner "PICK ROLES (size=${FLEET_SIZE})"
  mapfile -t PICKED_ROLES < <(pick_roles "$FLEET_SIZE")
  FILTERED=()
  for r in "${PICKED_ROLES[@]}"; do
    [ -n "$r" ] && FILTERED+=("$r") && log "  picked: $r"
  done
  PICKED_ROLES=("${FILTERED[@]}")
  if [ "${#PICKED_ROLES[@]}" -eq 0 ]; then
    log "WARN: no valid roles — sleeping ${TICK_INTERVAL_MINUTES}m"
    sleep "$((TICK_INTERVAL_MINUTES * 60))"
    continue
  fi

  # 3. Enqueue jobs. Use a fire-scoped result queue so late results from the
  # previous fire (H-01) land in their own key and can't be lost by a DEL here.
  fire_result_queue="${RESULT_QUEUE}:fire-${fire_id}"
  banner "ENQUEUE JOBS"
  for r in "${PICKED_ROLES[@]}"; do
    job=$(build_job_json "$fire_id" "$r" "$WORKER_TIMEOUT_MINUTES")
    redis LPUSH "$JOB_QUEUE" "$job" >/dev/null
    log "  enqueued: $r"
  done

  # 4. Await results
  banner "AWAIT RESULTS (timeout ${WORKER_TIMEOUT_MINUTES}m each, +5m grace)"
  results_collected=0
  total_files_written=0
  DEADLINE=$(( $(date +%s) + WORKER_TIMEOUT_MINUTES * 60 + 300 ))
  while [ "$results_collected" -lt "${#PICKED_ROLES[@]}" ]; do
    NOW=$(date +%s)
    [ "$NOW" -ge "$DEADLINE" ] && { log "WARN: deadline — $results_collected/${#PICKED_ROLES[@]}"; break; }
    REMAINING=$((DEADLINE - NOW))
    [ "$REMAINING" -gt 1800 ] && REMAINING=1800
    [ "$REMAINING" -lt 1 ] && REMAINING=1
    raw=$(redis BRPOP "$fire_result_queue" "$REMAINING" 2>/dev/null || true)
    payload=$(printf '%s\n' "$raw" | tail -n +2)
    [ -z "$payload" ] && { log "WARN: empty BRPOP"; continue; }
    role=$(printf '%s' "$payload" | jq -r '.role // "?"')
    files=$(printf '%s' "$payload" | jq -r '.files_written // 0' 2>/dev/null || echo 0)
    duration=$(printf '%s' "$payload" | jq -r '.duration_seconds // 0' 2>/dev/null || echo 0)
    log "  result: role=$role files=$files duration=${duration}s"
    total_files_written=$((total_files_written + files))
    results_collected=$((results_collected + 1))
    printf '%s\n' "$payload" > "$ORCH_DIR/WORKER_REPORTS/fire-${fire_id}-${role}.json"
  done

  # 5. Supervisor
  banner "SUPERVISOR PASS"
  decision="healthy"
  [ "$total_files_written" -eq 0 ] && decision="stuck:zero_files"
  log "supervisor: files=$total_files_written decision=$decision"
  append_supervisor "$fire_id" "$decision" "$total_files_written"
  if check_stuck; then write_stuck_marker "$fire_id"; fi

  # 6. Commit + optional push
  banner "COMMIT"
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git add -A
    git commit -m "chore(fleet): fire #${fire_id} — ${total_files_written} files, decision=${decision}" \
      --author="${GIT_AUTHOR_NAME:-fleet manager} <${GIT_AUTHOR_EMAIL:-manager@fleet.local}>" \
      2>/dev/null && log "commit OK" || log "WARN: commit failed"
  else
    log "no changes to commit"
  fi
  if [ "$AUTO_PUSH" = "true" ]; then
    git push origin "$BRANCH" 2>&1 | sed 's/^/  /' >&2 && log "push OK" || log "WARN: push failed"
  fi

  # Expire the scoped result queue — any stragglers after this point belong to
  # a dead fire and should not accumulate in Redis indefinitely.
  redis EXPIRE "$fire_result_queue" 3600 >/dev/null 2>&1 || true

  banner "FIRE #${fire_id} END — sleeping ${TICK_INTERVAL_MINUTES}m"
  sleep "$((TICK_INTERVAL_MINUTES * 60))"
done
