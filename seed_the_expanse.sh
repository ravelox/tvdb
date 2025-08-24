#!/usr/bin/env bash
set -euo pipefail

API="${API:-http://localhost:3000}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"; exit 1
fi

json() { jq -c -n "$1"; }

curl -s -o /dev/null -w "%{http_code}\n" -X POST "$API/init" | grep -qE '^(200|201|204)$' && echo "[init] Database ensured" || echo "[init] Skipped or not supported"

SHOW_ID=$(curl -s "$API/shows" | jq -r '
  map(select(.title=="The Expanse" and .year==2015)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(curl -s -X POST "$API/shows" -H 'Content-Type: application/json' -d "$(json '{title:"The Expanse", description:"American science fiction series", year:2015}')" | jq -r '.id')
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

existing_seasons=$(curl -s "$API/shows/$SHOW_ID/seasons")
printf '%s\n' "$SEASONS" | while IFS='|' read -r s y; do
  [ -z "$s" ] && continue
  if echo "$existing_seasons" | jq -e --argjson s "$s" 'map(.season_number)|index($s)' >/dev/null; then
    echo "Season $s already exists"
  else
    echo "Creating Season $s (year $y)"
    curl -s -X POST "$API/shows/$SHOW_ID/seasons" -H 'Content-Type: application/json' -d "$(jq -nc --argjson s "$s" --argjson y "$y" '{season_number:$s, year:$y}')" >/dev/null
  fi
done

read -r -d '' ACTORS <<'EOF2' || true
Steven Strait
Dominique Tipper
Cas Anvar
Wes Chatham
EOF2

actors_json=$(curl -s "$API/actors")
printf '%s\n' "$ACTORS" | while IFS= read -r name; do
  [ -z "$name" ] && continue
  if echo "$actors_json" | jq -e --arg n "$name" 'map(.name)|index($n)' >/dev/null; then
    echo "Actor exists: $name"
  else
    echo "Creating actor: $name"
    curl -s -X POST "$API/actors" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$name" '{name:$n}')" >/dev/null
  fi
done
actors_json=$(curl -s "$API/actors")

read -r -d '' CHAR_TO_ACTOR <<'EOF2' || true
James Holden|Steven Strait
Naomi Nagata|Dominique Tipper
Alex Kamal|Cas Anvar
Amos Burton|Wes Chatham
EOF2

chars_json=$(curl -s "$API/shows/$SHOW_ID/characters")
printf '%s\n' "$CHAR_TO_ACTOR" | while IFS='|' read -r char actor; do
  [ -z "$char" ] && continue
  if echo "$chars_json" | jq -e --arg n "$char" 'map(.name)|index($n)' >/dev/null; then
    echo "Character exists: $char"
  else
    echo "Creating character: $char (actor: $actor)"
    curl -s -X POST "$API/shows/$SHOW_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$char" --arg a "$actor" '{name:$n, actor_name:$a}')" >/dev/null
  fi
done

# --- known episodes ---
read -r -d '' EPISODES <<'EOF2' || true
1|2015-12-14|Dulcinea|Series premiere.
1|2015-12-22|The Big Empty|Holden's crew fights for survival.
2|2017-02-01|Safe|Season 2 opener.
2|2017-02-08|Doors & Corners|Season 2 continues.
3|2018-04-11|Fight or Flight|Season 3 opener.
4|2019-12-13|New Terra|Season 4 opener.
5|2020-12-16|Exodus|Season 5 opener.
6|2021-12-10|Strange Dogs|Season 6 opener.
EOF2

existing_eps=$(curl -s "$API/shows/$SHOW_ID/episodes")
printf '%s\n' "$EPISODES" | while IFS='|' read -r season air_date title description; do
  [ -z "$season" ] && continue
  if echo "$existing_eps" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t))|length>0' >/dev/null; then
    echo "Episode exists (S${season}): $title"
  else
    echo "Creating episode (S${season}): $title"
    jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season, air_date:$date, title:$t, description:$d}' | curl -s -X POST "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
  fi
  EP_ID=$(curl -s "$API/shows/$SHOW_ID/episodes" | jq -r --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t)) | (.[0].id // empty)')
  [ -z "$EP_ID" ] && { echo "Could not resolve episode id for season $season"; continue; }

  case "$season" in
    6) CHARS="James Holden|Naomi Nagata|Amos Burton" ;;
    *) CHARS="James Holden|Naomi Nagata|Alex Kamal|Amos Burton" ;;
  esac
  echo "$CHARS" | tr '|' '\n' | while IFS= read -r char; do
    [ -z "$char" ] && continue
    echo "  Linking $char"
    curl -s -X POST "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$char" '{character_name:$n}')" >/dev/null
  done
done

# --- create additional episodes to reach five per season ---
printf '%s\n' "$SEASONS" | while IFS='|' read -r season year; do
  [ -z "$season" ] && continue
  for ep in 2 3 4 5; do
    title="S${season}E${ep}"
    air_date=$(printf "%s-01-%02d" "$year" $((ep*7-6)))
    description="Episode ${ep} of season ${season}."
    if curl -s "$API/shows/$SHOW_ID/episodes" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t))|length>0' >/dev/null; then
      echo "Episode exists (S${season}E${ep}): $title"
    else
      echo "Creating episode (S${season}E${ep}): $title"
      jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season, air_date:$date, title:$t, description:$d}' | curl -s -X POST "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
    fi
    EP_ID=$(curl -s "$API/shows/$SHOW_ID/episodes" | jq -r --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t)) | (.[0].id // empty)')
    [ -z "$EP_ID" ] && { echo "Could not resolve episode id for season $season"; continue; }

    case "$season" in
      6) CHARS="James Holden|Naomi Nagata|Amos Burton" ;;
      *) CHARS="James Holden|Naomi Nagata|Alex Kamal|Amos Burton" ;;
    esac
    echo "$CHARS" | tr '|' '\n' | while IFS= read -r char; do
      [ -z "$char" ] && continue
      echo "  Linking $char"
      curl -s -X POST "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$char" '{character_name:$n}')" >/dev/null
    done
  done
done

echo "The Expanse seeding complete"
