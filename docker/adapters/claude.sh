#!/usr/bin/env bash
# Provider adapter: Claude Code CLI.
#
# Rides the host's Claude Max subscription via the mounted ~/.claude OAuth
# session — no API key, no per-token billing. This is the default provider and
# the highest-quality option.
#
# Every adapter exposes the same three things:
#   <provider>_run_agent  <prompt_file> <timeout_min> <model> <log_file>
#   <provider>_run_canary <model> <log_file>
#   <provider>_exhaustion_regex   (echoes a regex matching that provider's
#                                  rate-limit / quota / auth error text)

CLAUDE_EXHAUSTION_REGEX='anthropic[^"]{0,40}(rate.?limit|quota|insufficient|credit|billing)|claude[-_]?(api|code)[^"]{0,40}(rate.?limit|quota|insufficient|credit|billing)|"type"[^"]*"(rate_limit_error|overloaded_error|authentication_error|permission_error|insufficient_credit|billing_error)"|HTTP\/[12](\.[01])?[[:space:]]+429[^0-9]|status[[:space:]]+(code[[:space:]]+)?429[^0-9]|insufficient_balance|credit balance (too low|exhausted|depleted)|max[-_ ]?plan.{0,40}(limit|exceeded|expired)|exceeded your (monthly|daily|current) quota'

claude_exhaustion_regex() { printf '%s' "$CLAUDE_EXHAUSTION_REGEX"; }

claude_run_agent() {
  local prompt_file="$1" timeout_min="$2" model="$3" log_file="$4"
  timeout "${timeout_min}m" claude \
    --dangerously-skip-permissions \
    --model "$model" \
    --print \
    "$(cat "$prompt_file")" \
    > "$log_file" 2>&1
}

claude_run_canary() {
  local model="$1" log_file="$2"
  timeout 2m claude \
    --dangerously-skip-permissions \
    --model "$model" \
    --print \
    "respond with OK" \
    > "$log_file" 2>&1
}
