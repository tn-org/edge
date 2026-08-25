#!/bin/bash
# Create a database and its owner role on the shared PostgreSQL instance (idempotent).
#
# Usage: ./db-create.sh <database> [role] [password]
#   role defaults to the database name. The password is only needed the first time,
#   when the role does not exist yet; an existing role's password is left untouched.
#
# Runs against the edge-postgres container over docker exec, so it needs no client
# tools on the host and no superuser password.
set -euo pipefail

DB="${1:?Usage: db-create.sh <database> [role] [password]}"
ROLE="${2:-}"
PASSWORD="${3:-}"
[ -n "$ROLE" ] || ROLE="$DB"

# Names are embedded in SQL as quoted identifiers; restrict them to slug characters so
# quoting can never be broken.
for v in "$DB" "$ROLE"; do
  case "$v" in
    *[!a-z0-9_-]*|"" ) echo "Invalid name: $v (lowercase letters, digits, - and _)"; exit 1 ;;
  esac
done

docker inspect -f '{{.State.Running}}' edge-postgres >/dev/null 2>&1 || {
  echo "edge-postgres is not running (make db-up)"
  exit 1
}

psql_exec() {
  docker exec -i edge-postgres psql -U postgres -v ON_ERROR_STOP=1 -qAt -c "$1"
}

role_exists="$(psql_exec "SELECT 1 FROM pg_roles WHERE rolname = '$ROLE'")"
if [ -z "$role_exists" ]; then
  if [ -z "$PASSWORD" ]; then
    echo "Role $ROLE does not exist; a password is required to create it"
    echo "-> make db-create NAME=$DB ROLE=$ROLE PASSWORD=..."
    exit 1
  fi
  # Single quotes in the password are doubled for the SQL literal
  esc="${PASSWORD//\'/\'\'}"
  psql_exec "CREATE ROLE \"$ROLE\" LOGIN PASSWORD '$esc'" >/dev/null
  echo "Role created: $ROLE"
else
  echo "Role exists: $ROLE"
fi

db_exists="$(psql_exec "SELECT 1 FROM pg_database WHERE datname = '$DB'")"
if [ -z "$db_exists" ]; then
  psql_exec "CREATE DATABASE \"$DB\" OWNER \"$ROLE\"" >/dev/null
  echo "Database created: $DB (owner: $ROLE)"
else
  echo "Database exists: $DB"
fi
