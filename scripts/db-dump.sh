#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

print_usage() {
  cat <<'USAGE' >&2
Usage: scripts/db-dump.sh [--api URL] <output-file|->

Fetches the full database export from /admin/database-dump.
- Pass "-" to write the dump to stdout.
- Use --api to override the target base URL (or set API in the environment).
USAGE
}

API_OVERRIDE=""
OUTPUT_PATH=""

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
      OUTPUT_PATH="$1"
      shift
      break
      ;;
  esac
done

if [[ -z "$OUTPUT_PATH" && $# -gt 0 ]]; then
  OUTPUT_PATH="$1"
  shift
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  print_usage
  exit 1
fi

if [[ -n "$API_OVERRIDE" ]]; then
  export API="$API_OVERRIDE"
fi

# shellcheck source=scripts/seed_common.sh
source "$SCRIPT_DIR/seed_common.sh"

temp_dump=$(mktemp)
cleanup() { rm -f "$temp_dump"; }
trap cleanup EXIT

seed_init_database
seed_api_get "$API/admin/database-dump" >"$temp_dump"

final_path="$temp_dump"
if [[ "$OUTPUT_PATH" == "-" ]]; then
  cat "$temp_dump"
else
  mkdir -p "$(dirname "$OUTPUT_PATH")"
  mv "$temp_dump" "$OUTPUT_PATH"
  trap - EXIT
  final_path="$OUTPUT_PATH"
fi

if command -v jq >/dev/null 2>&1; then
  summary=$(jq -c 'to_entries | map({table: .key, rows: (.value | length)})' "$final_path")
  >&2 echo "Database dump written (${summary})"
else
  if [[ "$OUTPUT_PATH" == "-" ]]; then
    >&2 echo "Database dump streamed to stdout"
  else
    >&2 echo "Database dump written to ${OUTPUT_PATH}"
  fi
fi
