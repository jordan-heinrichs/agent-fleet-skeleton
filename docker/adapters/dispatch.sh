#!/usr/bin/env bash
# Provider dispatch. Sources every adapter in this directory and routes calls
# to the right one by provider name. The orchestration code (worker + manager)
# only ever calls these three wrappers, so it stays provider-agnostic.
#
# Add a new provider by dropping a <name>.sh in this directory that defines
# <name>_run_agent, <name>_run_canary, and <name>_exhaustion_regex. No
# registration step — dispatch picks it up automatically.

ADAPTER_DIR="${ADAPTER_DIR:-/usr/local/bin/adapters}"

# shellcheck source=/dev/null
for _adapter in "$ADAPTER_DIR"/*.sh; do
  [ "$(basename "$_adapter")" = "dispatch.sh" ] && continue
  [ -f "$_adapter" ] && . "$_adapter"
done
unset _adapter

# provider_run_agent  <provider> <prompt_file> <timeout_min> <model> <log_file>
provider_run_agent() {
  if ! command -v "${1}_run_agent" >/dev/null 2>&1; then
    echo "dispatch: unknown provider '${1}' (no ${1}_run_agent)" >&2
    return 127
  fi
  "${1}_run_agent" "$2" "$3" "$4" "$5"
}

# provider_run_canary <provider> <model> <log_file>
provider_run_canary() {
  if ! command -v "${1}_run_canary" >/dev/null 2>&1; then
    echo "dispatch: unknown provider '${1}' (no ${1}_run_canary)" >&2
    return 127
  fi
  "${1}_run_canary" "$2" "$3"
}

# provider_exhaustion_regex <provider>
provider_exhaustion_regex() {
  if command -v "${1}_exhaustion_regex" >/dev/null 2>&1; then
    "${1}_exhaustion_regex"
  fi
}
