#!/usr/bin/env bash
# One-time setup so the fleet starts cleanly on any machine. Safe to re-run.
#
# It does two small things:
#   1. Creates your .env from the template (your knobs; never committed).
#   2. Creates the host placeholders the Docker mounts expect, so
#      `docker compose up` works even if you only use Ollama and have never
#      installed Claude. Claude users already have these; this just makes the
#      bind mounts resolve for everyone else.
#
# Usage:
#   bash setup.sh
#   docker compose up -d --build
set -e

cd "$(dirname "$0")"

# 1. .env from the template
if [ -f .env ]; then
  echo "[ok] .env already exists, leaving it alone"
else
  cp .env.example .env
  echo "[new] created .env from .env.example, open it and pick your provider"
fi

# 2. Credential mount placeholders (~/.claude dir, ~/.claude.json file, ~/.ssh dir)
mkdir -p "$HOME/.claude" "$HOME/.ssh"
if [ ! -e "$HOME/.claude.json" ]; then
  printf '{}\n' > "$HOME/.claude.json"
fi
echo "[ok] credential placeholders ready (~/.claude, ~/.claude.json, ~/.ssh)"

echo
echo "Next:"
echo "  1. (optional) edit .env to choose claude or ollama"
echo "  2. docker compose up -d --build"
echo "  3. docker compose logs -f manager"
