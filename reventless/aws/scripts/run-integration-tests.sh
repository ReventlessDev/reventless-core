#!/usr/bin/env bash
# Boot a DynamoDB Local sidecar, run the DCB integration suite against it, tear
# down. Safe to run anywhere: if Docker is unavailable the suite is skipped (the
# CI step is continue-on-error, and not every dev machine has Docker running).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
COMPOSE="$ROOT/reventless/aws/docker-compose.dynamodb-local.yml"
ENDPOINT="${AWS_ENDPOINT_URL_DYNAMODB:-http://localhost:8000}"

if ! command -v docker >/dev/null 2>&1; then
  echo "⏭  Docker not available — skipping DCB DynamoDB integration tests"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "⏭  Docker daemon not running — skipping DCB DynamoDB integration tests"
  exit 0
fi

cleanup() { docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "▶  Starting DynamoDB Local…"
docker compose -f "$COMPOSE" up -d

# DynamoDB Local answers a bare GET with HTTP 400 once it is up — curl exits 0
# on any HTTP response, non-zero only on connection refused.
echo "⏳  Waiting for DynamoDB Local at $ENDPOINT…"
for i in $(seq 1 30); do
  if curl -s -o /dev/null "$ENDPOINT"; then
    echo "✓  DynamoDB Local is up"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "✗  DynamoDB Local did not start within 30s"
    exit 1
  fi
  sleep 1
done

cd "$ROOT"
NODE_OPTIONS='--experimental-vm-modules --no-warnings' \
  npx jest --config jest.integration.config.js "$@"
