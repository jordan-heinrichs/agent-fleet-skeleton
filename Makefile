# agent-fleet-skeleton — convenience commands.
#
# Optional. Everything here is a thin wrapper over `docker compose`, so if you
# don't have `make` (e.g. Windows without it), the README shows the raw
# commands too. macOS/Linux users get memorable shortcuts.

# Match container file ownership to the host user.
export UID := $(shell id -u 2>/dev/null || echo 1000)
export GID := $(shell id -g 2>/dev/null || echo 1000)

COMPOSE := docker compose

.DEFAULT_GOAL := help
.PHONY: help up down restart logs logs-worker status clean doctor ollama-pull

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-13s\033[0m %s\n", $$1, $$2}'

up: ## build + start the fleet (creates .env from the example if missing)
	@test -f .env || (cp .env.example .env && echo "created .env from .env.example — review it")
	$(COMPOSE) up -d --build
	@echo "fleet up. follow it with:  make logs"

down: ## stop + remove containers
	$(COMPOSE) down

restart: ## rebuild + restart (after editing entrypoints or .env)
	$(COMPOSE) up -d --build

logs: ## follow the manager log
	$(COMPOSE) logs -f manager

logs-worker: ## follow worker logs
	$(COMPOSE) logs -f worker

status: ## container status + the last few supervisor decisions
	@docker ps --filter name=fleet --filter name=worker \
	  --format "table {{.Names}}\t{{.Status}}" || true
	@echo "--- recent fires ---"
	@tail -n 5 orchestrator/SUPERVISOR_LOG.jsonl 2>/dev/null || echo "(no fires yet)"

clean: ## stop the fleet + wipe generated output (keeps your .env)
	-$(COMPOSE) down
	rm -rf projects/*/findings projects/*/synthesis \
	       orchestrator/WORKER_REPORTS orchestrator/last-canary*.log .aider*
	-git checkout -- orchestrator/ANTI_LOOP_LEDGER.md orchestrator/SUPERVISOR_LOG.jsonl 2>/dev/null
	@echo "cleaned."

doctor: ## check prerequisites (docker + your chosen provider)
	@echo "checking prerequisites..."
	@command -v docker >/dev/null 2>&1 && echo "  [ok] docker installed" || echo "  [MISSING] docker"
	@docker info >/dev/null 2>&1 && echo "  [ok] docker engine running" || echo "  [MISSING] docker engine not running"
	@test -d "$$HOME/.claude" && echo "  [ok] ~/.claude present (claude provider ready)" || echo "  [info] ~/.claude absent (needed only for the claude provider)"
	@curl -fsS -m 3 http://localhost:11434/api/version >/dev/null 2>&1 && echo "  [ok] ollama server reachable (ollama provider ready)" || echo "  [info] ollama not reachable on :11434 (needed only for the ollama provider)"

ollama-pull: ## pull the default local model (qwen2.5-coder:14b)
	@curl -fsS http://localhost:11434/api/pull -d '{"name":"qwen2.5-coder:14b"}' \
	  && echo "pulled qwen2.5-coder:14b" \
	  || echo "could not reach ollama on :11434 — is it installed and running?"
