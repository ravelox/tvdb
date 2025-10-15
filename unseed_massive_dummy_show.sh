#!/usr/bin/env bash
set -euo pipefail

API="${API:-http://localhost:3000}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/seed_common.sh
source "$SCRIPT_DIR/scripts/seed_common.sh"
# shellcheck source=scripts/unseed_common.sh
source "$SCRIPT_DIR/scripts/unseed_common.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

TITLE="${UNSEED_SHOW_TITLE:-${SHOW_TITLE:-Massive Export Showcase}}"
YEAR="${UNSEED_SHOW_YEAR:-${SHOW_YEAR:-2030}}"

unseed_show "$TITLE" "$YEAR"
