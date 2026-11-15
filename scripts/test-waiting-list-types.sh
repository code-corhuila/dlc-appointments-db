#!/usr/bin/env bash
# Disposable check for HU-APT-005/006: bootstrap, migrate (dev context) and run scripts/fixtures/waiting-list-types.sql.
# Creates and removes only its own container and network. Requires Docker.
set -euo pipefail
export MSYS_NO_PATHCONV=1
repo="$(cd "$(dirname "$0")/.." && pwd)"
command -v cygpath >/dev/null && repo="$(cygpath -m "$repo")"
name="apt-wl-test-$$"
pw="$(openssl rand -hex 16)"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; docker network rm "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker network create "$name" >/dev/null
docker run -d --name "$name" --network "$name" -e POSTGRES_DB=di_lucca -e POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:17.11-alpine3.24 >/dev/null
for _ in $(seq 1 30); do docker exec "$name" pg_isready -U postgres -d di_lucca >/dev/null 2>&1 && break; sleep 1; done
sleep 2
psql() { docker exec -i "$name" psql -q -v ON_ERROR_STOP=1 -U postgres -d di_lucca "$@"; }
psql -c "CREATE SCHEMA IF NOT EXISTS appointments_extensions; CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA appointments_extensions;" >/dev/null
psql < "$repo/deploy/bootstrap.sql" >/dev/null
psql -c "ALTER ROLE appointments_migrator PASSWORD '$pw';" >/dev/null
docker run --rm --network "$name" -v "$repo:/workspace:ro" -w /workspace -e DLC_ENVIRONMENT=dev \
  -e DLC_POSTGRES_HOST="$name" -e LIQUIBASE_COMMAND_PASSWORD="$pw" --entrypoint /bin/sh \
  liquibase/liquibase:4.33.0 /workspace/deploy/run-migration.sh update 2>&1 | grep -E 'Run:|successfully|ERROR' || true
psql < "$repo/scripts/fixtures/waiting-list-types.sql"
echo "waiting-list-types: PASS"
