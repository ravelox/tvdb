#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

print_usage() {
  cat <<'USAGE' >&2
Usage: scripts/db-import.sh [--api URL] <dump-file|->

Posts a previously captured database dump to /admin/database-import.
- Pass "-" to read the JSON payload from stdin.
- Use --api to override the target base URL (or set API in the environment).
USAGE
}

API_OVERRIDE=""
INPUT_PATH=""

while (( $# > 0 )); do
  case "$1" in
    --api)
      API_OVERRIDE="${2:-}"
      if [[ -z "$API_OVERRIDE" ]]; then
        echo "--api requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      print_usage
      exit 1
      ;;
    *)
      INPUT_PATH="$1"
      shift
      break
      ;;
  esac
done

if [[ -z "$INPUT_PATH" && $# -gt 0 ]]; then
  INPUT_PATH="$1"
  shift
fi

if [[ -z "$INPUT_PATH" ]]; then
  print_usage
  exit 1
fi

if [[ -n "$API_OVERRIDE" ]]; then
  export API="$API_OVERRIDE"
fi

# shellcheck source=scripts/seed_common.sh
source "$SCRIPT_DIR/seed_common.sh"

payload_path="$INPUT_PATH"
temp_payload=""
if [[ "$INPUT_PATH" == "-" ]]; then
  temp_payload=$(mktemp)
  payload_path="$temp_payload"
  trap 'rm -f "$temp_payload"' EXIT
  cat >"$payload_path"
else
  if [[ ! -f "$INPUT_PATH" ]]; then
    echo "Input file not found: $INPUT_PATH" >&2
    exit 1
  fi
fi

if [[ ! -s "$payload_path" ]]; then
  echo "Input payload is empty — refusing to import" >&2
  exit 1
fi

seed_init_database
response=$(seed_api_post "$API/admin/database-import" \
  -H 'Content-Type: application/json' \
  --data-binary "@$payload_path")

if command -v jq >/dev/null 2>&1; then
  status=$(printf '%s' "$response" | jq -r '.status // empty')
  counts=$(printf '%s' "$response" | jq -c '.counts // empty')
  if [[ -n "$status" ]]; then
    echo "Import ${status} (${counts})"
  else
    echo "$response"
  fi
else
  echo "$response"
fi
