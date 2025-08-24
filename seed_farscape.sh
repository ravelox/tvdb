#!/usr/bin/env bash
set -euo pipefail

API="${API:-http://localhost:3000}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"; exit 1
fi

json() { jq -c -n "$1"; }

curl -s -o /dev/null -w "%{http_code}\n" -X POST "$API/init" | grep -qE '^(200|201|204)$' && echo "[init] Database ensured" || echo "[init] Skipped or not supported"

SHOW_ID=$(curl -s "$API/shows" | jq -r '
  map(select(.title=="Farscape" and .year==1999)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(curl -s -X POST "$API/shows" -H 'Content-Type: application/json' -d "$(json '{title:"Farscape", description:"Australian-American science fiction series", year:1999}')" | jq -r '.id')
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
Ben Browder
Claudia Black
Anthony Simcoe
Gigi Edgley
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
John Crichton|Ben Browder
Aeryn Sun|Claudia Black
Ka D'Argo|Anthony Simcoe
Chiana|Gigi Edgley
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

# --- create 3 episodes per season ---
printf '%s\n' "$SEASONS" | while IFS='|' read -r season year; do
  [ -z "$season" ] && continue
  eps=$(curl -s "$API/shows/$SHOW_ID/seasons/$season/episodes")
  for ep in 1 2 3; do
    title="S${season}E${ep}"
    air_date=$(printf "%s-01-%02d" "$year" $((ep*7-6)))
    description="Episode ${ep} of season ${season}."
    if echo "$eps" | jq -e --arg t "$title" 'map(.title)|index($t)' >/dev/null; then
      echo "Episode exists (S${season}E${ep}): $title"
    else
      echo "Creating episode (S${season}E${ep}): $title"
      jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season, air_date:$date, title:$t, description:$d}' | curl -s -X POST "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
      eps=$(curl -s "$API/shows/$SHOW_ID/seasons/$season/episodes")
    fi
    EP_ID=$(echo "$eps" | jq -r --arg t "$title" 'map(select(.title==$t)) | (.[0].id // empty)')
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
      curl -s -X POST "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$char" '{character_name:$n}')" >/dev/null
    done
  done
done

echo "Farscape seeding complete"
