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
  map(select(.title=="Sapphire & Steel" and .year==1979)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(seed_api_post "$API/shows" \
    -H 'Content-Type: application/json' \
    -d "$(json '{title:"Sapphire & Steel", description:"ITV science fiction mystery serial", year:1979}')" \
    | jq -r '.id')
  echo "Created show: Sapphire & Steel (id=$SHOW_ID)"
else
  echo "Using existing show: Sapphire & Steel (id=$SHOW_ID)"
fi

read -r -d '' SEASONS <<'EOF_SEASONS' || true
1|1979
2|1979
3|1981
4|1981
5|1982
6|1982
EOF_SEASONS

existing_seasons=$(seed_api_get "$API/shows/$SHOW_ID/seasons")
printf '%s\n' "$SEASONS" | while IFS='|' read -r number year; do
  [ -z "$number" ] && continue
  if echo "$existing_seasons" | jq -e --argjson s "$number" 'map(.season_number)|index($s)' >/dev/null; then
    echo "Season $number already exists"
  else
    echo "Creating Season $number (year $year)"
    seed_api_post "$API/shows/$SHOW_ID/seasons" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --argjson s "$number" --argjson y "$year" '{season_number:$s, year:$y}')" >/dev/null
  fi
done

read -r -d '' EPISODES <<'EOF_EPISODES' || true
1|1979-07-10|Escape Through a Crack in Time: Part 1|Sapphire and Steel answer a plea from siblings whose parents vanish amid a time rupture.
1|1979-07-12|Escape Through a Crack in Time: Part 2|Steel uncovers time fragments stalking the house while Sapphire bonds with the children.
1|1979-07-17|Escape Through a Crack in Time: Part 3|The agents trace the disturbance to nursery rhymes echoing across history.
1|1979-07-19|Escape Through a Crack in Time: Part 4|A soldier torn from the past stalks the home as the rupture widens.
1|1979-07-24|Escape Through a Crack in Time: Part 5|The enemy lures Sapphire into the void, forcing Steel to improvise a rescue.
1|1979-07-26|Escape Through a Crack in Time: Part 6|Silver helps seal the temporal crack before it engulfs the Earth.
2|1979-07-31|The Railway Station: Part 1|At a deserted station, ghosts of 1917 haunt the living and draw the agents in.
2|1979-08-02|The Railway Station: Part 2|Steel confronts a spectral sergeant determined to replay wartime executions.
2|1979-08-07|The Railway Station: Part 3|Sapphire experiences the looped time of a wartime massacre.
2|1979-08-09|The Railway Station: Part 4|A volunteer evacuee reveals the force that feeds on grief.
2|1979-08-14|The Railway Station: Part 5|The investigators prepare a trap using Silver's time-forged equipment.
2|1979-08-16|The Railway Station: Part 6|The entity torments Sapphire with phantoms of the dead.
2|1979-08-21|The Railway Station: Part 7|Steel challenges the faceless officer commanding the time storm.
2|1979-08-23|The Railway Station: Part 8|Sapphire seals the railway rift and grants the spirits peace.
3|1981-01-06|The Creature's Revenge: Part 1|Antique photographs bleed time, drawing the agents to a rural house.
3|1981-01-07|The Creature's Revenge: Part 2|A creature imprisoned on film reaches through the developing trays.
3|1981-01-13|The Creature's Revenge: Part 3|Steel interrogates a survivor trapped within a snapshot.
3|1981-01-14|The Creature's Revenge: Part 4|Sapphire risks entrapment to learn the creature's motives.
3|1981-01-20|The Creature's Revenge: Part 5|Silver fashions a projector snare as time shards attack.
3|1981-01-21|The Creature's Revenge: Part 6|Steel forces the entity back into its film loop to free the victims.
4|1981-08-05|The Man Without a Face: Part 1|A faceless intruder steals people from a tower block in the night.
4|1981-08-06|The Man Without a Face: Part 2|Steel deduces that photographs have become gateways for the thief.
4|1981-08-11|The Man Without a Face: Part 3|Sapphire enters a child's memories to track the image world.
4|1981-08-12|The Man Without a Face: Part 4|Steel journeys into the photographs where the man harvests faces.
4|1981-08-18|The Man Without a Face: Part 5|Silver constructs a mirror prison to hold the entity at bay.
4|1981-08-19|The Man Without a Face: Part 6|The agents bargain to free the captives before reality unravels.
5|1982-08-11|Dr McDee Must Die: Part 1|Guests at a country house reenact a 1930s murder that turns deadly again.
5|1982-08-12|Dr McDee Must Die: Part 2|Sapphire senses time replaying the night of Dr. McDee's death.
5|1982-08-18|Dr McDee Must Die: Part 3|Steel interrogates the hosts as the partygoers become possessed.
5|1982-08-19|Dr McDee Must Die: Part 4|A time storm traps the house in a lethal masquerade.
5|1982-08-25|Dr McDee Must Die: Part 5|The murderer is unmasked but the house refuses to release the victims.
5|1982-08-26|Dr McDee Must Die: Part 6|The agents reset the evening to break the killing loop.
6|1982-08-31|The Trap: Part 1|The agents board a deserted space station after receiving a distress call.
6|1982-09-01|The Trap: Part 2|Steel uncovers a sinister card game that imprisons operatives.
6|1982-09-07|The Trap: Part 3|Sapphire is drawn into the game as the snare hunts for replacements.
6|1982-09-08|The Trap: Part 4|Sapphire and Steel accept exile to save humanity from the trap.
EOF_EPISODES

existing_eps=$(seed_api_get "$API/shows/$SHOW_ID/episodes")
printf '%s\n' "$EPISODES" | while IFS='|' read -r season air_date title description; do
  [ -z "$season" ] && continue
  if echo "$existing_eps" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t))|length>0' >/dev/null; then
    echo "Episode exists (S${season}): $title"
  else
    echo "Creating episode (S${season}): $title"
    jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season, air_date:$date, title:$t, description:$d}' |
      seed_api_post "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
  fi
done

echo "Sapphire & Steel seeding complete"
