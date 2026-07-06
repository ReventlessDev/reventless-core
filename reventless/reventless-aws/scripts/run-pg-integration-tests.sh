#!/usr/bin/env bash
# Boot a Postgres sidecar, run the PG_URL integration suites against it (serially,
# via jest.integration.pg.config.js), tear down. Safe to run anywhere: if Docker
# is unavailable the suites are skipped (the CI step is continue-on-error, and not
# every dev machine has Docker running).
#
# If PG_URL is already set (a dev's own Postgres), the sidecar is skipped and the
# suites run against that database instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
COMPOSE="$ROOT/reventless/reventless-aws/docker-compose.postgres.yml"

run_jest() {
  cd "$ROOT"
  NODE_OPTIONS='--experimental-vm-modules --no-warnings' \
    npx jest --config jest.integration.pg.config.js "$@"
}

# Honour a pre-set PG_URL (dev's own database) — no sidecar needed.
if [ -n "${PG_URL:-}" ]; then
  echo "▶  Using existing PG_URL — running PG integration suites"
  run_jest "$@"
  exit $?
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "⏭  Docker not available — skipping PG integration tests"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "⏭  Docker daemon not running — skipping PG integration tests"
  exit 0
fi

cleanup() { docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "▶  Starting Postgres…"
docker compose -f "$COMPOSE" up -d

echo "⏳  Waiting for Postgres…"
for i in $(seq 1 30); do
  if docker compose -f "$COMPOSE" exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
    echo "✓  Postgres is up"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "✗  Postgres did not start within 30s"
    exit 1
  fi
  sleep 1
done

# Host port matches docker-compose.postgres.yml's mapping (55433 → container 5432),
# chosen to avoid colliding with a dev's own Postgres on 5432.
export PG_URL="postgres://postgres:postgres@localhost:55433/postgres"
run_jest "$@"
