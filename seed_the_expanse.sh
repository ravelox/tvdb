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
  map(select(.title=="The Expanse" and .year==2015)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(seed_api_post "$API/shows" -H 'Content-Type: application/json' -d "$(json '{title:"The Expanse", description:"American science fiction series", year:2015}')" | jq -r '.id')
  echo "Created show: The Expanse (id=$SHOW_ID)"
else
  echo "Using existing show: The Expanse (id=$SHOW_ID)"
fi

read -r -d '' SEASONS <<'EOF2' || true
1|2015
2|2017
3|2018
4|2019
5|2020
6|2021
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
Steven Strait
Dominique Tipper
Cas Anvar
Wes Chatham
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
James Holden|Steven Strait
Naomi Nagata|Dominique Tipper
Alex Kamal|Cas Anvar
Amos Burton|Wes Chatham
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
1|2015-12-14|Dulcinea|Series premiere.
1|2015-12-22|The Big Empty|Holden's crew fights for survival.
1|2015-12-29|Remember the Cant|The Canterbury's destruction spreads chaos.
1|2016-01-05|CQB|The Rocinante is caught in a deadly battle.
1|2016-01-12|Back to the Butcher|Holden deals with sudden fame.
2|2017-02-01|Safe|Season 2 opener.
2|2017-02-01|Doors & Corners|Season 2 continues.
2|2017-02-08|Static|Holden struggles with Miller's actions.
2|2017-02-15|Godspeed|The Rocinante chases a dangerous threat.
2|2017-02-22|Home|A massive object heads for Earth.
3|2018-04-11|Fight or Flight|Season 3 opener.
3|2018-04-18|IFF|The Rocinante aids a UN ship.
3|2018-04-25|Assured Destruction|Earth considers a doomsday plan.
3|2018-05-02|Reload|The crew resupplies and faces new threats.
3|2018-05-09|Triple Point|Tensions at the Ring escalate.
4|2019-12-13|New Terra|Season 4 opener.
4|2019-12-13|Jetsam|Tensions on Ilus rise.
4|2019-12-13|Subduction|Holden confronts the planet's mysteries.
4|2019-12-13|Retrograde|A rescue mission turns dangerous.
4|2019-12-13|Oppressor|Murtry makes a ruthless move.
5|2020-12-16|Exodus|Season 5 opener.
5|2020-12-16|Churn|Holden pursues a new threat.
5|2020-12-16|Mother|Naomi reaches out to her son.
5|2020-12-23|Gaugamela|Earth and Mars are under attack.
5|2020-12-30|Down and Out|The crew deals with fallout.
6|2021-12-10|Strange Dogs|Season 6 opener.
6|2021-12-17|Azure Dragon|The Rocinante targets a rail-gun platform.
6|2021-12-24|Force Projection|Holden takes a risky shot.
6|2021-12-31|Redoubt|Drummer fights for allies.
6|2022-01-07|Why We Fight|The inner planets unite for war.
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

  case "$season" in
    6) CHARS="James Holden|Naomi Nagata|Amos Burton" ;;
    *) CHARS="James Holden|Naomi Nagata|Alex Kamal|Amos Burton" ;;
  esac
  echo "$CHARS" | tr '|' '\n' | while IFS= read -r char; do
    [ -z "$char" ] && continue
    echo "  Linking $char"
    seed_api_post "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$char" '{character_name:$n}')" >/dev/null
  done
done


echo "The Expanse seeding complete"
