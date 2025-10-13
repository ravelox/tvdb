#!/usr/bin/env bash
set -euo pipefail

# Seed a synthetic show with a very large number of oversized episodes so that
# /admin/database-dump exports roughly 30MB of JSON. Tunable via environment.

API="${API:-http://localhost:3000}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/seed_common.sh
source "$SCRIPT_DIR/scripts/seed_common.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"; exit 1
fi

SHOW_TITLE="${SHOW_TITLE:-Massive Export Showcase}"
SHOW_DESCRIPTION="${SHOW_DESCRIPTION:-Synthetic load fixture for exercising database export size limits.}"
SHOW_YEAR="${SHOW_YEAR:-2030}"

TOTAL_SEASONS=${TOTAL_SEASONS:-6}
EPISODES_PER_SEASON=${EPISODES_PER_SEASON:-250}
CHARACTERS_PER_EPISODE=${CHARACTERS_PER_EPISODE:-2}
DESCRIPTION_REPEATS=${DESCRIPTION_REPEATS:-320}

if (( TOTAL_SEASONS <= 0 || EPISODES_PER_SEASON <= 0 )); then
  echo "TOTAL_SEASONS and EPISODES_PER_SEASON must be positive integers" >&2
  exit 1
fi
if (( CHARACTERS_PER_EPISODE <= 0 )); then
  echo "CHARACTERS_PER_EPISODE must be a positive integer" >&2
  exit 1
fi

BASE_CHUNK="This filler text inflates the export payload for stress testing purposes."
CHUNK_LENGTH=$(( ${#BASE_CHUNK} + 1 ))
LONG_DESCRIPTION=""
for _ in $(seq 1 "$DESCRIPTION_REPEATS"); do
  LONG_DESCRIPTION+="$BASE_CHUNK "
done

seed_init_database

SHOW_ID=$(seed_api_get "$API/shows" | jq -r \
  --arg title "$SHOW_TITLE" --argjson year "$SHOW_YEAR" \
  'map(select(.title==$title and .year==$year)) | (.[0].id // empty)')

if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(seed_api_post "$API/shows" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg title "$SHOW_TITLE" --arg desc "$SHOW_DESCRIPTION" --argjson year "$SHOW_YEAR" \
      '{title:$title, description:$desc, year:$year}')" | jq -r '.id')
  echo "Created show: ${SHOW_TITLE} (id=$SHOW_ID)" >&2
else
  echo "Using existing show: ${SHOW_TITLE} (id=$SHOW_ID)" >&2
fi

read -r -d '' CHARACTER_ROSTER <<'EOF_ROSTER' || true
Nova Vector|Ada Quantum
Dex Byte|Troy Circuit
Rhea Horizon|Imani Pulse
Milo Flux|Ruben Signal
Kira Lattice|Elena Wave
Quinn Parsec|Noah Orbit
Vera Kernel|Sasha Logic
Orion Stack|Harper Thread
Lena Voltage|Maya Current
Ivo Beacon|Julian Phase
EOF_ROSTER

declare -a CHAR_NAMES=()
declare -a CHAR_ACTORS=()
while IFS='|' read -r c a; do
  [ -z "$c" ] && continue
  CHAR_NAMES+=("$c")
  CHAR_ACTORS+=("$a")
done <<<"$CHARACTER_ROSTER"

for idx in "${!CHAR_NAMES[@]}"; do
  actor_payload=$(jq -nc --arg name "${CHAR_ACTORS[$idx]}" '{name:$name}')
  seed_api_post "$API/actors" -H 'Content-Type: application/json' -d "$actor_payload" >/dev/null

  character_payload=$(jq -nc --arg name "${CHAR_NAMES[$idx]}" --arg actor "${CHAR_ACTORS[$idx]}" '{name:$name, actor_name:$actor}')
  seed_api_post "$API/shows/$SHOW_ID/characters" -H 'Content-Type: application/json' -d "$character_payload" >/dev/null
done

echo "Ensuring ${TOTAL_SEASONS} seasons..." >&2
for season in $(seq 1 "$TOTAL_SEASONS"); do
  season_year=$((SHOW_YEAR + season - 1))
  seed_api_post "$API/shows/$SHOW_ID/seasons" \
    -H 'Content-Type: application/json' \
    -d "$(jq -nc --argjson number "$season" --argjson year "$season_year" '{season_number:$number, year:$year}')" >/dev/null
done

CHAR_COUNT=${#CHAR_NAMES[@]}
if (( CHAR_COUNT == 0 )); then
  echo "Character roster is empty; cannot proceed" >&2
  exit 1
fi

episode_total=0
echo "Creating ${TOTAL_SEASONS} seasons x ${EPISODES_PER_SEASON} episodes (target ≈ 30MB export)..." >&2
for season in $(seq 1 "$TOTAL_SEASONS"); do
  for episode in $(seq 1 "$EPISODES_PER_SEASON"); do
    month=$(( ((episode - 1) / 28) % 12 + 1 ))
    day=$(( (episode - 1) % 28 + 1 ))
    air_date=$(printf '%04d-%02d-%02d' $((2040 + season)) "$month" "$day")
    title=$(printf 'Load Test S%02dE%03d' "$season" "$episode")
    description="Season ${season} Episode ${episode}. ${LONG_DESCRIPTION}"

    payload=$(jq -nc \
      --argjson season "$season" \
      --arg date "$air_date" \
      --arg title "$title" \
      --arg desc "$description" \
      '{season_number:$season, air_date:$date, title:$title, description:$desc}')

    response=$(seed_api_post "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d "$payload")
    episode_id=$(printf '%s' "$response" | jq -r '.id')
    if [ -z "$episode_id" ] || [ "$episode_id" = "null" ]; then
      echo "Failed to create episode ${title}" >&2
      exit 1
    fi

    for offset in $(seq 0 $((CHARACTERS_PER_EPISODE - 1))); do
      idx=$(( (episode + offset) % CHAR_COUNT ))
      char_name=${CHAR_NAMES[$idx]}
      link_payload=$(jq -nc --arg name "$char_name" '{character_name:$name}')
      seed_api_post "$API/episodes/$episode_id/characters" -H 'Content-Type: application/json' -d "$link_payload" >/dev/null
    done

    ((episode_total++))
    if (( episode_total % 100 == 0 )); then
      echo "  Processed ${episode_total} episodes..." >&2
    fi
  done
done

approx_size=$(( TOTAL_SEASONS * EPISODES_PER_SEASON * DESCRIPTION_REPEATS * CHUNK_LENGTH / 1024 ))
echo "Seed complete. Episodes created: ${episode_total}. Estimated dump size: ~${approx_size}KB plus metadata." >&2
echo "Run scripts/db-dump.sh - to verify the export size." >&2
