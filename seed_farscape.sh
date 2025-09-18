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
  map(select(.title=="Farscape" and .year==1999)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(seed_api_post "$API/shows" -H 'Content-Type: application/json' -d "$(json '{title:"Farscape", description:"Australian-American science fiction series", year:1999}')" | jq -r '.id')
  echo "Created show: Farscape (id=$SHOW_ID)"
else
  echo "Using existing show: Farscape (id=$SHOW_ID)"
fi

read -r -d '' SEASONS <<'EOF2' || true
1|1999
2|2000
3|2001
4|2002
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
Ben Browder
Claudia Black
Anthony Simcoe
Gigi Edgley
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
John Crichton|Ben Browder
Aeryn Sun|Claudia Black
Ka D'Argo|Anthony Simcoe
Chiana|Gigi Edgley
EOF2

chars_json=$(seed_api_get "$API/shows/$SHOW_ID/characters")
printf '%s\n' "$CHAR_TO_ACTOR" | while IFS='|' read -r char actor; do
  [ -z "$char" ] && continue
  if echo "$chars_json" | jq -e --arg n "$char" 'map(.name)|index($n)' >/dev/null; then
    echo "Character exists: $char"
  else
    echo "Creating character: $char (actor: $actor)"
    seed_api_post "$API/shows/$SHOW_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$char" --arg a "$actor" '{name:$n, actor_name:$a}')" >/dev/null
  fi
done

# --- known episodes ---
read -r -d '' EPISODES <<'EOF2' || true
1|1999-03-19|Premiere|Series premiere.
1|1999-03-26|I, E.T.|Crichton helps a stranded alien.
1|1999-04-09|Exodus from Genesis|Moya is infested with heat-seeking bugs.
1|1999-04-23|Throne for a Loss|A crime lord kidnaps Rygel.
1|1999-04-30|Back and Back and Back to the Future|Time-twisting visitors cause trouble.
2|2000-03-17|Mind the Baby|Season 2 opener.
2|2000-03-24|Vitas Mortis|D'Argo aids a dying Luxan.
2|2000-03-31|Taking the Stone|Chiana joins thrill-seekers on a perilous planet.
2|2000-04-07|Crackers Don't Matter|A scientist's device drives the crew mad.
2|2000-04-14|The Way We Weren't|Aeryn's past comes to light.
3|2001-03-16|Season of Death|Season 3 opener.
3|2001-03-23|Suns and Lovers|The crew is trapped in a dangerous storm.
3|2001-04-06|Self-Inflicted Wounds: Could'a, Would'a, Should'a|A wormhole merges ships.
3|2001-04-13|Self-Inflicted Wounds: Wait for the Wheel|Crichton must make a painful choice.
3|2001-04-20|Different Destinations|A time glitch alters history.
4|2002-06-07|Crichton Kicks|Season 4 opener.
4|2002-06-14|What Was Lost: A Gift from a Bad God|The crew returns to a desolate world.
4|2002-06-21|What Was Lost: Resurrection|The crew fights Scorpius.
4|2002-06-28|Lava's a Many Splendored Thing|The crew seeks riches in a lava planet.
4|2002-07-05|Promises|Aeryn returns with a secret.
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
    1) CHARS="John Crichton|Aeryn Sun|Ka D'Argo" ;;
    2|3) CHARS="John Crichton|Aeryn Sun|Ka D'Argo|Chiana" ;;
    4) CHARS="John Crichton|Chiana" ;;
    *) CHARS="" ;;
  esac
  echo "$CHARS" | tr '|' '\n' | while IFS= read -r char; do
    [ -z "$char" ] && continue
    echo "  Linking $char"
    seed_api_post "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$char" '{character_name:$n}')" >/dev/null
  done
done


echo "Farscape seeding complete"
