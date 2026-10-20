#!/usr/bin/env bash
# `podman compose` for this stack: base file + per-account file, profiles from .env.
# podman-compose does not read COMPOSE_FILE / COMPOSE_PROFILES from .env, so pass them as flags.
#   scripts/compose.sh up -d li-postgres
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo ".env missing: cp .env.example .env and fill it in first"; exit 1; }
set -a; . ./.env; set +a
[[ -f docker-compose.accounts.yml ]] || cp docker-compose.accounts.yml.example docker-compose.accounts.yml

args=(-f docker-compose.yml -f docker-compose.accounts.yml)
for p in ${COMPOSE_PROFILES//,/ }; do args+=(--profile "$p"); done
exec podman compose "${args[@]}" "$@"
