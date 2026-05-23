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
MAX_FLEET_SIZE="${MAX_FLEET_SIZE:-4}"
MIN_TICK_INTERVAL_MINUTES="${MIN_TICK_INTERVAL_MINUTES:-5}"
REDIS_URL="${REDIS_URL:-redis://redis:6379}"
JOB_QUEUE="${JOB_QUEUE:-fleet:jobs}"
RESULT_QUEUE="${RESULT_QUEUE:-fleet:results}"
WORKER_TIMEOUT_MINUTES="${WORKER_TIMEOUT_MINUTES:-25}"
ACTIVE_PACK="${ACTIVE_PACK:-example-research}"
PACK_DIR="packs/${ACTIVE_PACK}"
BRANCH="${BRANCH:-main}"
AUTO_PUSH="${AGENT_AUTO_PUSH:-false}"
ORCH_DIR="orchestrator"
LEDGER_FILE="${ORCH_DIR}/ANTI_LOOP_LEDGER.md"
NORTH_STAR_FILE="${ORCH_DIR}/NORTH_STAR.json"
SUPERVISOR_LOG="${ORCH_DIR}/SUPERVISOR_LOG.jsonl"
STUCK_FILE="${ORCH_DIR}/STUCK.md"
PAUSE_BASE_MINUTES="${PAUSE_BASE_MINUTES:-30}"

# ── Provider selection (mirrors the worker) ─────────────────────────────────
# The manager canaries the primary provider before each fire. If the primary
# canary fails but a fallback is configured, it proceeds anyway — the workers
# will fall back per-job. CANARY_MODEL is the cheap model used for the ping
# (e.g. Haiku for Claude; for Ollama the canary just hits the local server).
AGENT_PROVIDER="${AGENT_PROVIDER:-claude}"
AGENT_FALLBACK="${AGENT_FALLBACK:-}"
CANARY_MODEL="${CANARY_MODEL:-claude-haiku-4-5-20251001}"
FALLBACK_CANARY_MODEL="${FALLBACK_CANARY_MODEL:-qwen2.5-coder:14b}"

# Adapters provide run_canary / exhaustion_regex per provider.
ADAPTER_DIR="${ADAPTER_DIR:-/usr/local/bin/adapters}"
# shellcheck source=/dev/null
. "${ADAPTER_DIR}/dispatch.sh"

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

_REDIS_SAFE=$(printf '%s' "$REDIS_URL" | sed 's|://[^@]*@|://***@|')
log "boot: tick=${TICK_INTERVAL_MINUTES}m size=$FLEET_SIZE redis=$_REDIS_SAFE pack=$ACTIVE_PACK"
unset _REDIS_SAFE

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

# Restore fire_id from Redis so it never resets after a manager restart.
# A reset would re-use IDs whose fire-scoped result queues may still be live
# in Redis (within their 1-hour TTL), causing stale results to be collected.
fire_id=$(redis GET fleet:fire_id 2>/dev/null || echo "")
case "$fire_id" in ''|*[!0-9]*) fire_id=0 ;; esac
log "boot: resuming from fire_id=$fire_id"

# H-02: On boot, recover any jobs left in the processing queue by a previous
# crash — move them back so they get retried this session.
orphaned=$(redis LLEN "${JOB_QUEUE}-processing" 2>/dev/null || echo 0)
if [ "${orphaned:-0}" -gt 0 ] 2>/dev/null; then
  for _i in $(seq 1 "$orphaned"); do
    redis LMOVE "${JOB_QUEUE}-processing" "$JOB_QUEUE" LEFT RIGHT >/dev/null 2>&1 || true
  done
  log "requeued $orphaned orphaned job(s) from previous crash"
fi

# Discover roles from the active pack's ROLES.md (`## <name>` headings).
discover_roles() {
  grep -oE '^## [a-z][a-z0-9-]+' "${PACK_DIR}/ROLES.md" 2>/dev/null \
    | sed -E 's/^## //'
}

# Pick FLEET_SIZE roles, biased toward those with the lowest count in the ledger.
pick_roles() {
  local n="$1"
  local role count
  declare -A counts
  mapfile -t ROLES < <(discover_roles)
  if [ "${#ROLES[@]}" -eq 0 ]; then
    log "WARN: no roles found in ${PACK_DIR}/ROLES.md"
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
    --arg pack "$ACTIVE_PACK" \
    '{fire_id: ($fire_id|tonumber), role: $role, pack: $pack, dispatched_at: $ts, timeout_minutes: ($timeout|tonumber)}'
}

# Canary — verify Claude auth + credits with a cheap Haiku call before the fire.
# Canary one provider via its adapter. Returns 0 if healthy.
canary_one() {
  local provider="$1" model="$2" canary_log="$3"
  log "canary: pinging $provider:$model ..."
  provider_run_canary "$provider" "$model" "$canary_log"
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    log "canary FAILED: $provider exit=$exit_code (see $canary_log)"
    return 1
  fi
  local rx; rx="$(provider_exhaustion_regex "$provider")"
  if [ -n "$rx" ] && grep -qiE "$rx" "$canary_log" 2>/dev/null; then
    log "canary: $provider exhaustion signal in response"
    return 1
  fi
  log "canary: $provider OK"
  return 0
}

# Canary the primary provider. If it fails but a fallback is configured, canary
# the fallback — a healthy fallback is enough to dispatch the fire (workers
# fall back per-job). Only a total wipeout (primary down, no working fallback)
# blocks the fire.
canary_check() {
  local tick="$1"
  if canary_one "$AGENT_PROVIDER" "$CANARY_MODEL" "${ORCH_DIR}/last-canary.log"; then
    return 0
  fi
  if [ -n "$AGENT_FALLBACK" ]; then
    log "canary: primary ($AGENT_PROVIDER) down — checking fallback $AGENT_FALLBACK"
    if canary_one "$AGENT_FALLBACK" "$FALLBACK_CANARY_MODEL" "${ORCH_DIR}/last-canary-fallback.log"; then
      log "canary: fallback healthy — dispatching (workers will fall back per-job)"
      return 0
    fi
  fi
  return 1
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

# Governor — reads last 20 worker sessions, steps fleet_size / tick_interval
# up or down based on throttle rate, writes RUNTIME_CONFIG.json for the monitor.
# Only the manager Redis user has write access to fleet:config.
governor_pass() {
  local fire_id="$1"
  local window=20 throttle_count=0 total_count=0 throttle_pct=0
  local cur_fleet cur_tick new_fleet new_tick final_fleet final_tick

  while IFS= read -r f; do
    local status
    status=$(jq -r '.status // ""' "$f" 2>/dev/null)
    [ -z "$status" ] && continue
    total_count=$((total_count + 1))
    case "$status" in exhausted|fast_fail) throttle_count=$((throttle_count + 1));; esac
  done < <(ls -t "$ORCH_DIR/WORKER_REPORTS"/fire-*.json 2>/dev/null | head -"$window")

  cur_fleet=$(redis HGET fleet:config fleet_size 2>/dev/null || echo "")
  cur_tick=$(redis HGET fleet:config tick_interval_minutes 2>/dev/null || echo "")
  case "$cur_fleet" in ''|*[!0-9]*) cur_fleet="$FLEET_SIZE";; esac
  case "$cur_tick"  in ''|*[!0-9]*) cur_tick="$TICK_INTERVAL_MINUTES";; esac

  local max_fleet min_tick
  max_fleet="$MAX_FLEET_SIZE"; min_tick="$MIN_TICK_INTERVAL_MINUTES"
  case "$max_fleet" in ''|*[!0-9]*) max_fleet=4;; esac
  case "$min_tick"  in ''|*[!0-9]*) min_tick=5;; esac

  if [ "$total_count" -gt 0 ]; then
    throttle_pct=$(( throttle_count * 100 / total_count ))
  fi

  if [ "$throttle_pct" -ge 50 ]; then
    new_fleet=$(( cur_fleet > 1 ? cur_fleet - 1 : 1 ))
    new_tick=$(( cur_tick + 5 < 120 ? cur_tick + 5 : 120 ))
    redis HSET fleet:config fleet_size "$new_fleet" tick_interval_minutes "$new_tick" >/dev/null
    log "governor: throttle=${throttle_pct}% (${throttle_count}/${total_count}) → fleet=$new_fleet tick=${new_tick}m [step down]"
  elif [ "$throttle_pct" -eq 0 ] && [ "$total_count" -ge "$window" ]; then
    new_fleet=$(( cur_fleet < max_fleet ? cur_fleet + 1 : max_fleet ))
    new_tick=$(( cur_tick > min_tick + 4 ? cur_tick - 5 : min_tick ))
    redis HSET fleet:config fleet_size "$new_fleet" tick_interval_minutes "$new_tick" >/dev/null
    log "governor: clear window (${total_count}) → fleet=$new_fleet tick=${new_tick}m [step up]"
  else
    log "governor: throttle=${throttle_pct}% (${throttle_count}/${total_count}) — holding fleet=$cur_fleet tick=${cur_tick}m"
  fi

  final_fleet=$(redis HGET fleet:config fleet_size 2>/dev/null || echo "")
  final_tick=$(redis HGET fleet:config tick_interval_minutes 2>/dev/null || echo "")
  case "$final_fleet" in ''|*[!0-9]*) final_fleet="$cur_fleet";; esac
  case "$final_tick"  in ''|*[!0-9]*) final_tick="$cur_tick";; esac

  jq -nc \
    --arg fleet     "$final_fleet" --arg tick        "$final_tick" \
    --arg fleet_def "$FLEET_SIZE"  --arg tick_def    "$TICK_INTERVAL_MINUTES" \
    --arg max_fleet "$max_fleet"   --arg min_tick    "$min_tick" \
    --arg tpct      "$throttle_pct" --arg tcount     "$throttle_count" \
    --arg total     "$total_count"  --arg fire_id    "$fire_id" \
    --arg ts        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{fleet_size:($fleet|tonumber),tick_interval_minutes:($tick|tonumber),
      fleet_size_default:($fleet_def|tonumber),tick_interval_default:($tick_def|tonumber),
      max_fleet_size:($max_fleet|tonumber),min_tick_interval:($min_tick|tonumber),
      throttle_pct:($tpct|tonumber),throttle_count:($tcount|tonumber),
      total_sessions_checked:($total|tonumber),updated_fire:($fire_id|tonumber),ts:$ts}' \
    > "$ORCH_DIR/RUNTIME_CONFIG.json" 2>/dev/null || true
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

  # Refresh live config from Redis — governor may have adjusted it last tick.
  _rc_fleet=$(redis HGET fleet:config fleet_size 2>/dev/null || echo "")
  _rc_tick=$(redis HGET fleet:config tick_interval_minutes 2>/dev/null || echo "")
  case "$_rc_fleet" in ''|*[!0-9]*) ;; *) FLEET_SIZE="$_rc_fleet";; esac
  case "$_rc_tick"  in ''|*[!0-9]*) ;; *) TICK_INTERVAL_MINUTES="$_rc_tick";; esac
  log "tick config: fleet=$FLEET_SIZE interval=${TICK_INTERVAL_MINUTES}m"

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

  # 3. Enqueue jobs into a fire-scoped result queue (H-01: late results from the
  # previous fire land in their own key and are never lost by a DEL here).
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
  # The manager owns the anti-loop ledger now. Workers cannot write
  # orchestrator/ (it is mounted read-only — see C-01). Each result carries
  # a .new_files[] array; we accumulate ledger lines here and append once,
  # deduped, after the fire so parallel find-diff overlap can't double-list.
  LEDGER_TMP=$(mktemp)
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
    # Pull ledger lines straight from the result envelope.
    printf '%s' "$payload" \
      | jq -r '.new_files[]? as $f | "- \($f) ← \(.role) (fire #\(.fire_id))"' \
      >> "$LEDGER_TMP" 2>/dev/null || true
  done

  # Append accumulated ledger lines, deduped by full line, newest fire last.
  if [ -s "$LEDGER_TMP" ]; then
    awk '!seen[$0]++' "$LEDGER_TMP" >> "$LEDGER_FILE"
    log "ledger: appended $(awk '!seen[$0]++' "$LEDGER_TMP" | wc -l | tr -d ' ') entries"
  fi
  rm -f "$LEDGER_TMP"

  # 5. Supervisor
  banner "SUPERVISOR PASS"
  decision="healthy"
  [ "$total_files_written" -eq 0 ] && decision="stuck:zero_files"
  log "supervisor: files=$total_files_written decision=$decision"
  append_supervisor "$fire_id" "$decision" "$total_files_written"
  if check_stuck; then write_stuck_marker "$fire_id"; fi

  # 6. Governor — adjust fleet_size / tick_interval based on rolling throttle rate.
  banner "GOVERNOR PASS"
  governor_pass "$fire_id"

  # 7. Commit + optional push
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

  # Expire the fire-scoped result queue — stragglers after this belong to a
  # dead fire and should not accumulate in Redis indefinitely.
  redis EXPIRE "$fire_result_queue" 3600 >/dev/null 2>&1 || true

  banner "FIRE #${fire_id} END — sleeping ${TICK_INTERVAL_MINUTES}m"
  sleep "$((TICK_INTERVAL_MINUTES * 60))"
done
