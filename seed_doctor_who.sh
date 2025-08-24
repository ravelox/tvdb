#!/usr/bin/env bash
set -euo pipefail

API="${API:-http://localhost:3000}"   # change if your API runs elsewhere

# Requires jq
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"; exit 1
fi

json() { jq -c -n "$1"; }             # helper to build compact JSON

# --- Optional: ensure DB/schema exists (idempotent) ---
curl -s -o /dev/null -w "%{http_code}\n" -X POST "$API/init" | grep -qE '^(200|201|204)$' &&   echo "[init] Database ensured" || echo "[init] Skipped or not supported"

# --- find or create the show (Doctor Who, 1963) ---
SHOW_ID=$(curl -s "$API/shows" | jq -r '
  map(select(.title=="Doctor Who" and .year==1963)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(curl -s -X POST "$API/shows"     -H 'Content-Type: application/json'     -d "$(json '{title:"Doctor Who", description:"BBC science fiction series (Classic era)", year:1963}')"   | jq -r '.id')
  echo "Created show: Doctor Who (id=$SHOW_ID)"
else
  echo "Using existing show: Doctor Who (id=$SHOW_ID)"
fi

# --- season -> starting broadcast year map (Classic seasons 1–26) ---
read -r -d '' SEASON_YEAR <<'EOF' || true
1|1963
2|1964
3|1965
4|1966
5|1967
6|1968
7|1970
8|1971
9|1972
10|1972
11|1973
12|1974
13|1975
14|1976
15|1977
16|1978
17|1979
18|1980
19|1982
20|1983
21|1984
22|1985
23|1986
24|1987
25|1988
26|1989
EOF

lookup_year() {
  awk -F'|' -v s="$1" '$1==s {print $2; found=1; exit} END{ if(!found) exit 1 }' <<EOF
$SEASON_YEAR
EOF
}

# --- season -> episode count (IMDb) ---
# Counts cross-referenced with https://www.imdb.com/title/tt0056751/ for
# the classic 1963 series. Used to create placeholder episodes matching
# the real number per season.
read -r -d '' SEASON_EPISODE_COUNT <<'EOF' || true
1|42
2|39
3|45
4|43
5|40
6|44
7|25
8|25
9|26
10|26
11|26
12|20
13|26
14|26
15|26
16|26
17|26
18|28
19|26
20|28
21|24
22|13
23|14
24|14
25|14
26|14
EOF

lookup_epcount() {
  awk -F'|' -v s="$1" '$1==s {print $2; found=1; exit} END{ if(!found) exit 1 }' <<EOF
$SEASON_EPISODE_COUNT
EOF
}

# --- create seasons 1..26 if missing ---
existing_seasons_json=$(curl -s "$API/shows/$SHOW_ID/seasons")
for s in $(seq 1 26); do
  if echo "$existing_seasons_json" | jq -e --argjson s "$s" 'map(.season_number) | index($s)' >/dev/null; then
    echo "Season $s already exists"
  else
    y="$(lookup_year "$s" || true)"
    echo "Creating Season $s (year ${y:-null})..."
    if [ -n "${y:-}" ]; then
      curl -s -X POST "$API/shows/$SHOW_ID/seasons"         -H 'Content-Type: application/json'         -d "$(jq -nc --argjson s "$s" --argjson y "$y" '{season_number:$s, year:$y}')" >/dev/null
    else
      curl -s -X POST "$API/shows/$SHOW_ID/seasons"         -H 'Content-Type: application/json'         -d "$(jq -nc --argjson s "$s" '{season_number:$s, year:null}')" >/dev/null
    fi
  fi
done

# --- ensure actors (subset) ---
read -r -d '' ACTORS <<'EOF' || true
William Hartnell
Patrick Troughton
Jon Pertwee
Tom Baker
Peter Davison
Colin Baker
Sylvester McCoy
Elisabeth Sladen
Nicholas Courtney
Sophie Aldred
Katy Manning
Sarah Sutton
Nicola Bryant
Bonnie Langford
Lalla Ward
Louise Jameson
Carole Ann Ford
William Russell
Jacqueline Hill
John Leeson
EOF

echo "Ensuring actors..."
actors_json=$(curl -s "$API/actors")
printf '%s\n' "$ACTORS" | while IFS= read -r name; do
  [ -z "$name" ] && continue
  if echo "$actors_json" | jq -e --arg n "$name" 'map(.name) | index($n)' >/dev/null; then
    echo "  Actor exists: $name"
  else
    echo "  Creating actor: $name"
    curl -s -X POST "$API/actors" -H 'Content-Type: application/json'       -d "$(jq -nc --arg n "$name" '{name:$n}')" >/dev/null
  fi
done

# refresh
actors_json=$(curl -s "$API/actors")

# --- characters -> actors (subset we seed) ---
read -r -d '' CHAR_TO_ACTOR <<'EOF' || true
The Doctor (First Doctor)|William Hartnell
The Doctor (Second Doctor)|Patrick Troughton
The Doctor (Third Doctor)|Jon Pertwee
The Doctor (Fourth Doctor)|Tom Baker
The Doctor (Fifth Doctor)|Peter Davison
The Doctor (Sixth Doctor)|Colin Baker
The Doctor (Seventh Doctor)|Sylvester McCoy
Susan Foreman|Carole Ann Ford
Ian Chesterton|William Russell
Barbara Wright|Jacqueline Hill
Sarah Jane Smith|Elisabeth Sladen
Brigadier Lethbridge-Stewart|Nicholas Courtney
Leela|Louise Jameson
Romana|Lalla Ward
Peri Brown|Nicola Bryant
Ace|Sophie Aldred
Nyssa|Sarah Sutton
Jo Grant|Katy Manning
Mel Bush|Bonnie Langford
K9|John Leeson
EOF

echo "Ensuring characters..."
chars_json=$(curl -s "$API/shows/$SHOW_ID/characters")
printf '%s\n' "$CHAR_TO_ACTOR" | while IFS='|' read -r char actor; do
  [ -z "$char" ] && continue
  if echo "$chars_json" | jq -e --arg n "$char" 'map(.name) | index($n)' >/dev/null; then
    echo "  Character exists: $char"
  else
    echo "  Creating character: $char (actor: $actor)"
    curl -s -X POST "$API/shows/$SHOW_ID/characters" -H 'Content-Type: application/json'       -d "$(jq -nc --arg n "$char" --arg a "$actor" '{name:$n, actor_name:$a}')" >/dev/null
  fi
done

# --- episodes: known season openers ---
read -r -d '' EPISODES <<'EOF' || true
1|1963-11-23|An Unearthly Child|Series premiere.
1|1963-12-21|The Daleks|First Dalek story.
2|1964-10-31|Planet of Giants|Season 2 opener.
2|1964-11-21|The Dalek Invasion of Earth|Daleks invade Earth.
3|1965-09-11|Galaxy 4: Four Hundred Dawns|Season 3 opener.
4|1966-09-10|The Smugglers|Season 4 opener.
5|1967-09-02|The Tomb of the Cybermen|Season 5 opener.
6|1968-08-10|The Dominators|Season 6 opener.
7|1970-01-03|Spearhead from Space|Season 7 opener.
8|1971-01-02|Terror of the Autons|Season 8 opener.
9|1972-01-01|Day of the Daleks|Season 9 opener.
10|1972-12-30|The Three Doctors|Season 10 opener.
11|1973-12-15|The Time Warrior|Season 11 opener.
12|1974-12-28|Robot|Season 12 opener.
13|1975-08-30|Terror of the Zygons|Season 13 opener.
14|1976-09-04|The Masque of Mandragora|Season 14 opener.
15|1977-09-03|Horror of Fang Rock|Season 15 opener.
16|1978-09-02|The Ribos Operation|Season 16 opener.
17|1979-09-01|Destiny of the Daleks|Season 17 opener.
18|1980-08-30|The Leisure Hive|Season 18 opener.
19|1982-01-04|Castrovalva|Season 19 opener.
20|1983-01-03|Arc of Infinity|Season 20 opener.
21|1984-01-05|Warriors of the Deep|Season 21 opener.
22|1985-01-05|Attack of the Cybermen|Season 22 opener.
23|1986-09-06|The Trial of a Time Lord: The Mysterious Planet (Pt 1)|Season 23 opener.
24|1987-09-07|Time and the Rani|Season 24 opener.
25|1988-10-05|Remembrance of the Daleks|Season 25 opener.
26|1989-09-06|Battlefield|Season 26 opener.
EOF

echo "Ensuring known episodes..."
existing_eps=$(curl -s "$API/shows/$SHOW_ID/episodes")
printf '%s\n' "$EPISODES" | while IFS='|' read -r season air_date title description; do
  [ -z "$season" ] && continue
  if echo "$existing_eps" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | length > 0' >/dev/null; then
    echo "  Episode exists (S${season}): $title"
  else
    echo "  Creating episode (S${season}): $title"
    jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season, air_date:$date, title:$t, description:$d}' | curl -s -X POST "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
  fi

  EP_ID=$(curl -s "$API/shows/$SHOW_ID/episodes" | jq -r --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | (.[0].id // empty)')
  [ -z "$EP_ID" ] && { echo "  Could not resolve episode id for season $season"; continue; }

  case "$season" in
    1|2|3|4)   DOC="The Doctor (First Doctor)" ;;
    5|6)       DOC="The Doctor (Second Doctor)" ;;
    7|8|9|10|11) DOC="The Doctor (Third Doctor)" ;;
    12|13|14|15|16|17|18) DOC="The Doctor (Fourth Doctor)" ;;
    19|20|21) DOC="The Doctor (Fifth Doctor)" ;;
    22|23)    DOC="The Doctor (Sixth Doctor)" ;;
    *)        DOC="The Doctor (Seventh Doctor)" ;;
  esac
  echo "  S$season: linking $DOC -> $title"
  curl -s -X POST "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$DOC" '{character_name:$n}')" >/dev/null

  case "$season" in
    1) COMP="Susan Foreman|Ian Chesterton|Barbara Wright" ;;
    2) COMP="Susan Foreman|Ian Chesterton|Barbara Wright" ;;
    7) COMP="Brigadier Lethbridge-Stewart" ;;
    11|12|13|14) COMP="Sarah Jane Smith" ;;
    15) COMP="Leela" ;;
    16|17|18) COMP="Romana|K9" ;;
    19|20) COMP="Nyssa" ;;
    22|23) COMP="Peri Brown" ;;
    24) COMP="Mel Bush" ;;
    25|26) COMP="Ace" ;;
    *) COMP="" ;;
  esac
  if [ -n "$COMP" ]; then
    echo "$COMP" | tr '|' '\n' | while IFS= read -r c; do
      [ -z "$c" ] && continue
      echo "    + $c"
      curl -s -X POST "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$c" '{character_name:$n}')" >/dev/null
    done
  fi
done

# --- create placeholder episodes to match IMDb counts ---
echo "Ensuring additional episodes..."
for season in $(seq 1 26); do
  total="$(lookup_epcount "$season" || true)"
  [ -z "$total" ] && continue
  y="$(lookup_year "$season" || true)"
  existing_count=$(curl -s "$API/shows/$SHOW_ID/seasons/$season/episodes" | jq 'length')
  if [ "$existing_count" -ge "$total" ]; then
    echo "Season $season already has $existing_count episodes"
    continue
  fi
  for ep in $(seq $((existing_count+1)) "$total"); do
    title="S${season}E${ep}"
    air_date=$(date -d "${y:-1900}-01-01 +$((ep-1)) weeks" +%Y-%m-%d 2>/dev/null || printf "%s-01-01" "${y:-1900}")
    description="Episode ${ep} of season ${season}."
    if curl -s "$API/shows/$SHOW_ID/episodes" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | length > 0' >/dev/null; then
      echo "  Episode exists (S${season}E${ep}): $title"
    else
      echo "  Creating episode (S${season}E${ep}): $title"
      jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season,air_date:$date, title:$t, description:$d}' | curl -s -X POST "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
    fi

    EP_ID=$(curl -s "$API/shows/$SHOW_ID/episodes" | jq -r --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | (.[0].id // empty)')
    [ -z "$EP_ID" ] && { echo "  Could not resolve episode id for season $season"; continue; }

    case "$season" in
      1|2|3|4)   DOC="The Doctor (First Doctor)" ;;
      5|6)       DOC="The Doctor (Second Doctor)" ;;
      7|8|9|10|11) DOC="The Doctor (Third Doctor)" ;;
      12|13|14|15|16|17|18) DOC="The Doctor (Fourth Doctor)" ;;
      19|20|21) DOC="The Doctor (Fifth Doctor)" ;;
      22|23)    DOC="The Doctor (Sixth Doctor)" ;;
      *)        DOC="The Doctor (Seventh Doctor)" ;;
    esac
    echo "  S$season: linking $DOC -> $title"
    curl -s -X POST "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$DOC" '{character_name:$n}')" >/dev/null

    case "$season" in
      1) COMP="Susan Foreman|Ian Chesterton|Barbara Wright" ;;
      2) COMP="Susan Foreman|Ian Chesterton|Barbara Wright" ;;
      7) COMP="Brigadier Lethbridge-Stewart" ;;
      11|12|13|14) COMP="Sarah Jane Smith" ;;
      15) COMP="Leela" ;;
      16|17|18) COMP="Romana|K9" ;;
      19|20) COMP="Nyssa" ;;
      22|23) COMP="Peri Brown" ;;
      24) COMP="Mel Bush" ;;
      25|26) COMP="Ace" ;;
      *) COMP="" ;;
    esac
    if [ -n "$COMP" ]; then
      echo "$COMP" | tr '|' '\n' | while IFS= read -r c; do
        [ -z "$c" ] && continue
        echo "    + $c"
        curl -s -X POST "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$c" '{character_name:$n}')" >/dev/null
      done
    fi
  done
done

echo "Seeding complete with episode-character links."
