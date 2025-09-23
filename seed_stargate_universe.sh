#!/usr/bin/env bash
set -euo pipefail

API="${API:-http://localhost:3000}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/seed_common.sh
source "$SCRIPT_DIR/scripts/seed_common.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"; exit 1
fi

json() { jq -c -n "$1"; }

seed_init_database

SHOW_ID=$(seed_api_get "$API/shows" | jq -r '
  map(select(.title=="Stargate Universe" and .year==2009)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(seed_api_post "$API/shows" -H 'Content-Type: application/json' -d "$(json '{title:"Stargate Universe", description:"Canadian-American military science fiction series", year:2009}')" | jq -r '.id')
  echo "Created show: Stargate Universe (id=$SHOW_ID)"
else
  echo "Using existing show: Stargate Universe (id=$SHOW_ID)"
fi

read -r -d '' SEASONS <<'EOF2' || true
1|2009
2|2010
EOF2

existing_seasons=$(seed_api_get "$API/shows/$SHOW_ID/seasons")
printf '%s\n' "$SEASONS" | while IFS='|' read -r s y; do
  [ -z "$s" ] && continue
  if echo "$existing_seasons" | jq -e --argjson s "$s" 'map(.season_number)|index($s)' >/dev/null; then
    echo "Season $s already exists"
  else
    echo "Creating Season $s (year $y)"
    seed_api_post "$API/shows/$SHOW_ID/seasons" -H 'Content-Type: application/json' -d "$(jq -nc --argjson s "$s" --argjson y "$y" '{season_number:$s, year:$y}')" >/dev/null
  fi
done

read -r -d '' ACTORS <<'EOF2' || true
Robert Carlyle
Louis Ferreira
David Blue
Elyse Levesque
EOF2

actors_json=$(seed_api_get "$API/actors")
printf '%s\n' "$ACTORS" | while IFS= read -r name; do
  [ -z "$name" ] && continue
  if echo "$actors_json" | jq -e --arg n "$name" 'map(.name)|index($n)' >/dev/null; then
    echo "Actor exists: $name"
  else
    echo "Creating actor: $name"
    seed_api_post "$API/actors" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$name" '{name:$n}')" >/dev/null
  fi
done
actors_json=$(seed_api_get "$API/actors")

read -r -d '' CHAR_TO_ACTOR <<'EOF2' || true
Dr. Nicholas Rush|Robert Carlyle
Col. Everett Young|Louis Ferreira
Eli Wallace|David Blue
Chloe Armstrong|Elyse Levesque
EOF2

chars_json=$(seed_api_get "$API/shows/$SHOW_ID/characters")
printf '%s\n' "$CHAR_TO_ACTOR" | while IFS='|' read -r char actor; do
  [ -z "$char" ] && continue
  existing_char=$(echo "$chars_json" | jq -c --arg n "$char" 'map(select(.name==$n)) | (.[0] // empty)')
  if [ -n "$existing_char" ]; then
    current_actor=$(printf '%s' "$existing_char" | jq -r '.actor_name // ""')
    char_id=$(printf '%s' "$existing_char" | jq -r '.id')
    if [ -n "$actor" ] && [ "$current_actor" != "$actor" ]; then
      if [ -n "$current_actor" ]; then
        echo "Updating actor for $char -> $actor"
      else
        echo "Setting actor for $char -> $actor"
      fi
      seed_api_put "$API/characters/$char_id" -H 'Content-Type: application/json' -d "$(jq -nc --arg a "$actor" '{actor_name:$a}')" >/dev/null
    else
      echo "Character exists: $char (actor: ${current_actor:-none})"
    fi
  else
    echo "Creating character: $char (actor: $actor)"
    seed_api_post "$API/shows/$SHOW_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$char" --arg a "$actor" '{name:$n, actor_name:$a}')" >/dev/null
  fi
done

# --- known episodes ---
read -r -d '' EPISODES <<'EOF2' || true
1|2009-10-02|Air (Part 1)|Series premiere.
1|2009-10-09|Air (Part 2)|Continuation of the premiere.
1|2009-10-16|Air (Part 3)|The stranded crew searches for water.
1|2009-10-23|Darkness|Power failures threaten the ship.
1|2009-10-30|Light|The crew faces death as the ship heads for a star.
2|2010-09-28|Intervention|Season 2 opener.
2|2010-10-05|Aftermath|Young faces the consequences of command.
2|2010-10-12|Awakening|An encounter with an Ancient seed ship.
2|2010-10-19|Pathogen|Chloe undergoes strange changes.
2|2010-10-26|Cloverdale|Scott lives an alternate reality.
EOF2

existing_eps=$(seed_api_get "$API/shows/$SHOW_ID/episodes")
printf '%s\n' "$EPISODES" | while IFS='|' read -r season air_date title description; do
  [ -z "$season" ] && continue
  if echo "$existing_eps" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t))|length>0' >/dev/null; then
    echo "Episode exists (S${season}): $title"
  else
    echo "Creating episode (S${season}): $title"
    jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season, air_date:$date, title:$t, description:$d}' | seed_api_post "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
  fi
  EP_ID=$(seed_api_get "$API/shows/$SHOW_ID/episodes" | jq -r --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t)) | (.[0].id // empty)')
  [ -z "$EP_ID" ] && { echo "Could not resolve episode id for season $season"; continue; }
  for char in "Dr. Nicholas Rush" "Col. Everett Young" "Eli Wallace" "Chloe Armstrong"; do
    echo "  Linking $char"
    seed_api_post "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$char" '{character_name:$n}')" >/dev/null
  done
done


echo "Stargate Universe seeding complete"
