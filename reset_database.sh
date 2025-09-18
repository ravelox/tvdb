#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR="$SCRIPT_DIR"

if [[ -f "$REPO_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "$REPO_DIR/.env"
  set +a
fi

DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-3306}
DB_USER=${DB_USER:-root}
DB_PASSWORD=${DB_PASSWORD:-}
DB_NAME=${DB_NAME:-tvdb}
SCHEMA_PATH=${SCHEMA_PATH:-"$REPO_DIR/schema.sql"}
MYSQL_BIN=${MYSQL_BIN:-mysql}
FORCE=false

usage() {
  cat <<USAGE
Usage: $0 [--force]

Drops and recreates the "$DB_NAME" database, then reloads schema.sql so the
API starts from a clean slate. Connection settings default to the same
environment variables server.js consumes (DB_HOST, DB_PORT, DB_USER,
DB_PASSWORD, DB_NAME) and fall back to localhost/root/tvdb when not set.

Options:
  --force, -f   Skip the confirmation prompt.
  --help, -h    Show this help message.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)
      FORCE=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ ! -f "$SCHEMA_PATH" ]]; then
  echo "Schema file not found at $SCHEMA_PATH" >&2
  exit 1
fi

if ! command -v "$MYSQL_BIN" >/dev/null 2>&1; then
  echo "The mysql client is required but was not found in PATH" >&2
  exit 1
fi

if ! $FORCE; then
  echo "This will ERASE all data in database '$DB_NAME' on $DB_HOST:$DB_PORT."
  read -rp "Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

mysql_args=(--host "$DB_HOST" --port "$DB_PORT" --user "$DB_USER" --protocol tcp)

run_mysql() {
  if [[ -n "$DB_PASSWORD" ]]; then
    MYSQL_PWD="$DB_PASSWORD" "$MYSQL_BIN" "${mysql_args[@]}" "$@"
  else
    "$MYSQL_BIN" "${mysql_args[@]}" "$@"
  fi
}

echo "Verifying MySQL connectivity..."
run_mysql --execute 'SELECT 1' >/dev/null

echo "Dropping database '$DB_NAME' (if it exists)..."
escaped_db_name=$(printf '%s' "$DB_NAME" | sed 's/`/``/g')
drop_sql=$(printf 'DROP DATABASE IF EXISTS `%s`;' "$escaped_db_name")
run_mysql --execute "$drop_sql"

echo "Recreating database '$DB_NAME'..."
create_sql=$(printf 'CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' "$escaped_db_name")
run_mysql --execute "$create_sql"

echo "Reapplying schema from $SCHEMA_PATH..."
if [[ -n "$DB_PASSWORD" ]]; then
  MYSQL_PWD="$DB_PASSWORD" "$MYSQL_BIN" "${mysql_args[@]}" --database "$DB_NAME" <"$SCHEMA_PATH"
else
  "$MYSQL_BIN" "${mysql_args[@]}" --database "$DB_NAME" <"$SCHEMA_PATH"
fi

echo "Database reset complete. You can now reseed the API."
