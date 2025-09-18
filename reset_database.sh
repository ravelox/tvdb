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

PORT=${PORT:-3000}
API_BASE_URL=${API_BASE_URL:-"http://localhost:${PORT}"}
CURL_BIN=${CURL_BIN:-curl}
API_TOKEN=${API_TOKEN:-}
FORCE=false

usage() {
  cat <<USAGE
Usage: $0 [--force]

Resets the database by calling the POST /admin/reset-database API endpoint.
The request targets $API_BASE_URL (default http://localhost:${PORT}) and
includes the x-api-token header when $API_TOKEN is set.

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

if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
  echo "The curl client is required but was not found in PATH" >&2
  exit 1
fi

TARGET_URL="${API_BASE_URL%/}/admin/reset-database"

echo "Ready to reset the database via $TARGET_URL"
if [[ -z "$API_TOKEN" ]]; then
  echo "Warning: API_TOKEN is unset; the request will be unauthenticated" >&2
fi

if ! $FORCE; then
  echo "This will ERASE all data exposed by the API at $TARGET_URL."
  read -rp "Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

curl_args=("$CURL_BIN" --fail --silent --show-error -X POST "$TARGET_URL")
if [[ -n "$API_TOKEN" ]]; then
  curl_args+=(--header "x-api-token: $API_TOKEN")
fi

echo "Invoking API reset..."
set +e
response="$(${curl_args[@]} 2>&1)"
status=$?
set -e
if [[ $status -ne 0 ]]; then
  echo "$response" >&2
  echo "Database reset failed" >&2
  exit $status
fi

if [[ -n "$response" ]]; then
  echo "$response"
fi

echo "Database reset complete via API."
