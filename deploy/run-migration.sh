#!/bin/sh
set -eu

# Same command for every environment; only host, database, secret and contexts change.
case "${DLC_ENVIRONMENT:-}" in
  dev|qa|prod) ;;
  *) echo "Set DLC_ENVIRONMENT to dev, qa or prod" >&2; exit 2 ;;
esac

if [ -f /run/secrets/appointments_migrator_password ]; then
  LIQUIBASE_COMMAND_PASSWORD=$(cat /run/secrets/appointments_migrator_password)
  export LIQUIBASE_COMMAND_PASSWORD
fi
: "${LIQUIBASE_COMMAND_PASSWORD:?Mount the appointments_migrator_password secret}"

exec liquibase \
  --search-path=/workspace \
  --changelog-file=changelog/changelog-master.yaml \
  --url="jdbc:postgresql://${DLC_POSTGRES_HOST:-dlc-postgres}:5432/${DLC_POSTGRES_DB:-di_lucca}" \
  --username=appointments_migrator \
  --liquibase-schema-name=appointments_liquibase \
  --contexts="$DLC_ENVIRONMENT" \
  --analytics-enabled=false \
  "$@"
