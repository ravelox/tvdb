#!/usr/bin/env bash
set -euo pipefail

API="${API:-http://localhost:3000}"   # change if your API runs elsewhere

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/seed_common.sh
source "$SCRIPT_DIR/scripts/seed_common.sh"

# Requires jq
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required"; exit 1
fi

json() { jq -c -n "$1"; }             # helper to build compact JSON

# --- Optional: ensure DB/schema exists (idempotent) ---
seed_init_database

# --- find or create the show (Doctor Who, 1963) ---
SHOW_ID=$(seed_api_get "$API/shows" | jq -r '
  map(select(.title=="Doctor Who" and .year==1963)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(seed_api_post "$API/shows"     -H 'Content-Type: application/json'     -d "$(json '{title:"Doctor Who", description:"BBC science fiction series (Classic era)", year:1963}')"   | jq -r '.id')
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

format_episode_code() {
  local season="$1"
  local episode="$2"
  printf 'S%02dE%02d' "$((10#$season))" "$((10#$episode))"
}

# --- create seasons 1..26 if missing ---
existing_seasons_json=$(seed_api_get "$API/shows/$SHOW_ID/seasons")
for s in $(seq 1 26); do
  if echo "$existing_seasons_json" | jq -e --argjson s "$s" 'map(.season_number) | index($s)' >/dev/null; then
    echo "Season $s already exists"
  else
    y="$(lookup_year "$s" || true)"
    echo "Creating Season $s (year ${y:-null})..."
    if [ -n "${y:-}" ]; then
      seed_api_post "$API/shows/$SHOW_ID/seasons"         -H 'Content-Type: application/json'         -d "$(jq -nc --argjson s "$s" --argjson y "$y" '{season_number:$s, year:$y}')" >/dev/null
    else
      seed_api_post "$API/shows/$SHOW_ID/seasons"         -H 'Content-Type: application/json'         -d "$(jq -nc --argjson s "$s" '{season_number:$s, year:null}')" >/dev/null
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
Maureen O'Brien
Peter Purves
Michael Craze
Anneke Wills
Frazer Hines
Deborah Watling
Wendy Padbury
Caroline John
Ian Marter
Mary Tamm
Matthew Waterhouse
Janet Fielding
Mark Strickson
EOF

echo "Ensuring actors..."
actors_json=$(seed_api_get "$API/actors")
printf '%s\n' "$ACTORS" | while IFS= read -r name; do
  [ -z "$name" ] && continue
  if echo "$actors_json" | jq -e --arg n "$name" 'map(.name) | index($n)' >/dev/null; then
    echo "  Actor exists: $name"
  else
    echo "  Creating actor: $name"
    seed_api_post "$API/actors" -H 'Content-Type: application/json'       -d "$(jq -nc --arg n "$name" '{name:$n}')" >/dev/null
  fi
done

# refresh
actors_json=$(seed_api_get "$API/actors")

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
Vicki|Maureen O'Brien
Steven Taylor|Peter Purves
Ben Jackson|Michael Craze
Polly|Anneke Wills
Jamie McCrimmon|Frazer Hines
Victoria Waterfield|Deborah Watling
Zoe Heriot|Wendy Padbury
Liz Shaw|Caroline John
Sarah Jane Smith|Elisabeth Sladen
Brigadier Lethbridge-Stewart|Nicholas Courtney
Harry Sullivan|Ian Marter
Leela|Louise Jameson
Romana I|Mary Tamm
Romana II|Lalla Ward
Adric|Matthew Waterhouse
Nyssa|Sarah Sutton
Tegan Jovanka|Janet Fielding
Vislor Turlough|Mark Strickson
Jo Grant|Katy Manning
Peri Brown|Nicola Bryant
Mel Bush|Bonnie Langford
Ace|Sophie Aldred
K9|John Leeson
EOF

echo "Ensuring characters..."
chars_json=$(seed_api_get "$API/shows/$SHOW_ID/characters")
printf '%s\n' "$CHAR_TO_ACTOR" | while IFS='|' read -r char actor; do
  [ -z "$char" ] && continue
  existing_char=$(echo "$chars_json" | jq -c --arg n "$char" 'map(select(.name==$n)) | (.[0] // empty)')
  if [ -n "$existing_char" ]; then
    current_actor=$(printf '%s' "$existing_char" | jq -r '.actor_name // ""')
    char_id=$(printf '%s' "$existing_char" | jq -r '.id')
    if [ -n "$actor" ] && [ "$current_actor" != "$actor" ]; then
      if [ -n "$current_actor" ]; then
        echo "  Updating actor for $char -> $actor"
      else
        echo "  Setting actor for $char -> $actor"
      fi
      seed_api_put "$API/characters/$char_id" -H 'Content-Type: application/json'       -d "$(jq -nc --arg a "$actor" '{actor_name:$a}')" >/dev/null
    else
      echo "  Character exists: $char (actor: ${current_actor:-none})"
    fi
  else
    echo "  Creating character: $char (actor: $actor)"
    seed_api_post "$API/shows/$SHOW_ID/characters" -H 'Content-Type: application/json'       -d "$(jq -nc --arg n "$char" --arg a "$actor" '{name:$n, actor_name:$a}')" >/dev/null
  fi
done

# --- episodes: complete classic series catalogue ---
read -r -d '' EPISODES <<'EOF' || true
1||An Unearthly Child|Episode 1 of "An Unearthly Child".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Cave of Skulls|Episode 2 of "An Unearthly Child".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Forest of Fear|Episode 3 of "An Unearthly Child".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Firemaker|Episode 4 of "An Unearthly Child".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Dead Planet|Episode 1 of "The Daleks".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Survivors|Episode 2 of "The Daleks".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Escape|Episode 3 of "The Daleks".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Ambush|Episode 4 of "The Daleks".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Expedition|Episode 5 of "The Daleks".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Ordeal|Episode 6 of "The Daleks".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Rescue|Episode 7 of "The Daleks".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Edge of Destruction|Episode 1 of "The Edge of Destruction".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Brink of Disaster|Episode 2 of "The Edge of Destruction".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Roof of the World|Episode 1 of "Marco Polo".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Singing Sands|Episode 2 of "Marco Polo".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Five Hundred Eyes|Episode 3 of "Marco Polo".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Wall of Lies|Episode 4 of "Marco Polo".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Rider from Shang-Tu|Episode 5 of "Marco Polo".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Mighty Kublai Khan|Episode 6 of "Marco Polo".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Assassin at Peking|Episode 7 of "Marco Polo".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Sea of Death|Episode 1 of "The Keys of Marinus".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Velvet Web|Episode 2 of "The Keys of Marinus".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Screaming Jungle|Episode 3 of "The Keys of Marinus".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Snows of Terror|Episode 4 of "The Keys of Marinus".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Sentence of Death|Episode 5 of "The Keys of Marinus".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Keys of Marinus|Episode 6 of "The Keys of Marinus".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Temple of Evil|Episode 1 of "The Aztecs".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Warriors of Death|Episode 2 of "The Aztecs".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Bride of Sacrifice|Episode 3 of "The Aztecs".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Day of Darkness|Episode 4 of "The Aztecs".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Strangers in Space|Episode 1 of "The Sensorites".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Unwilling Warriors|Episode 2 of "The Sensorites".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Hidden Danger|Episode 3 of "The Sensorites".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||A Race Against Death|Episode 4 of "The Sensorites".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Kidnap|Episode 5 of "The Sensorites".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||A Desperate Venture|Episode 6 of "The Sensorites".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||A Land of Fear|Episode 1 of "The Reign of Terror".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Guests of Madame Guillotine|Episode 2 of "The Reign of Terror".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||A Change of Identity|Episode 3 of "The Reign of Terror".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||The Tyrant of France|Episode 4 of "The Reign of Terror".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||A Bargain of Necessity|Episode 5 of "The Reign of Terror".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1||Prisoners of Conciergerie|Episode 6 of "The Reign of Terror".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||Planet of Giants|Episode 1 of "Planet of Giants".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||Dangerous Journey|Episode 2 of "Planet of Giants".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||Crisis|Episode 3 of "Planet of Giants".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||World's End|Episode 1 of "The Dalek Invasion of Earth".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||The Daleks|Episode 2 of "The Dalek Invasion of Earth".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||Day of Reckoning|Episode 3 of "The Dalek Invasion of Earth".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||The End of Tomorrow|Episode 4 of "The Dalek Invasion of Earth".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||The Waking Ally|Episode 5 of "The Dalek Invasion of Earth".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||Flashpoint|Episode 6 of "The Dalek Invasion of Earth".|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2||The Powerful Enemy|Episode 1 of "The Rescue".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||Desperate Measures|Episode 2 of "The Rescue".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Slave Traders|Episode 1 of "The Romans".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||All Roads Lead to Rome|Episode 2 of "The Romans".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||Conspiracy|Episode 3 of "The Romans".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||Inferno|Episode 4 of "The Romans".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Web Planet|Episode 1 of "The Web Planet".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Zarbi|Episode 2 of "The Web Planet".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||Escape to Danger|Episode 3 of "The Web Planet".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||Crater of Needles|Episode 4 of "The Web Planet".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||Invasion|Episode 5 of "The Web Planet".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Centre|Episode 6 of "The Web Planet".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Lion|Episode 1 of "The Crusade".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Knight of Jaffa|Episode 2 of "The Crusade".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Wheel of Fortune|Episode 3 of "The Crusade".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Warlords|Episode 4 of "The Crusade".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Space Museum|Episode 1 of "The Space Museum".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Dimensions of Time|Episode 2 of "The Space Museum".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Search|Episode 3 of "The Space Museum".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Final Phase|Episode 4 of "The Space Museum".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Executioners|Episode 1 of "The Chase".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Death of Time|Episode 2 of "The Chase".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||Flight Through Eternity|Episode 3 of "The Chase".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||Journey into Terror|Episode 4 of "The Chase".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Death of Doctor Who|Episode 5 of "The Chase".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Planet of Decision|Episode 6 of "The Chase".|The Doctor (First Doctor);Ian Chesterton;Barbara Wright;Vicki
2||The Watcher|Episode 1 of "The Time Meddler".|The Doctor (First Doctor);Vicki;Steven Taylor
2||The Meddling Monk|Episode 2 of "The Time Meddler".|The Doctor (First Doctor);Vicki;Steven Taylor
2||A Battle of Wits|Episode 3 of "The Time Meddler".|The Doctor (First Doctor);Vicki;Steven Taylor
2||Checkmate|Episode 4 of "The Time Meddler".|The Doctor (First Doctor);Vicki;Steven Taylor
3||Four Hundred Dawns|Episode 1 of "Galaxy 4".|The Doctor (First Doctor);Vicki;Steven Taylor
3||Trap of Steel|Episode 2 of "Galaxy 4".|The Doctor (First Doctor);Vicki;Steven Taylor
3||Air Lock|Episode 3 of "Galaxy 4".|The Doctor (First Doctor);Vicki;Steven Taylor
3||The Exploding Planet|Episode 4 of "Galaxy 4".|The Doctor (First Doctor);Vicki;Steven Taylor
3||Mission to the Unknown|Episode 1 of "Mission to the Unknown".|
3||Temple of Secrets|Episode 1 of "The Myth Makers".|The Doctor (First Doctor);Vicki;Steven Taylor
3||Small Prophet, Quick Return|Episode 2 of "The Myth Makers".|The Doctor (First Doctor);Vicki;Steven Taylor
3||Death of a Spy|Episode 3 of "The Myth Makers".|The Doctor (First Doctor);Vicki;Steven Taylor
3||Horse of Destruction|Episode 4 of "The Myth Makers".|The Doctor (First Doctor);Vicki;Steven Taylor
3||The Nightmare Begins|Episode 1 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||Day of Armageddon|Episode 2 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||Devil's Planet|Episode 3 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||The Traitors|Episode 4 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||Counter Plot|Episode 5 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||Coronas of the Sun|Episode 6 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||The Feast of Steven|Episode 7 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||Volcano|Episode 8 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||Golden Death|Episode 9 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||Escape Switch|Episode 10 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||The Abandoned Planet|Episode 11 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||Destruction of Time|Episode 12 of "The Daleks' Master Plan".|The Doctor (First Doctor);Steven Taylor
3||War of God|Episode 1 of "The Massacre".|The Doctor (First Doctor);Steven Taylor
3||The Sea Beggar|Episode 2 of "The Massacre".|The Doctor (First Doctor);Steven Taylor
3||Priest of Death|Episode 3 of "The Massacre".|The Doctor (First Doctor);Steven Taylor
3||Bell of Doom|Episode 4 of "The Massacre".|The Doctor (First Doctor);Steven Taylor
3||The Steel Sky|Episode 1 of "The Ark".|The Doctor (First Doctor);Steven Taylor
3||The Plague|Episode 2 of "The Ark".|The Doctor (First Doctor);Steven Taylor
3||The Return|Episode 3 of "The Ark".|The Doctor (First Doctor);Steven Taylor
3||The Bomb|Episode 4 of "The Ark".|The Doctor (First Doctor);Steven Taylor
3||The Celestial Toyroom|Episode 1 of "The Celestial Toymaker".|The Doctor (First Doctor);Steven Taylor
3||The Hall of Dolls|Episode 2 of "The Celestial Toymaker".|The Doctor (First Doctor);Steven Taylor
3||The Dancing Floor|Episode 3 of "The Celestial Toymaker".|The Doctor (First Doctor);Steven Taylor
3||The Final Test|Episode 4 of "The Celestial Toymaker".|The Doctor (First Doctor);Steven Taylor
3||A Holiday for the Doctor|Episode 1 of "The Gunfighters".|The Doctor (First Doctor);Steven Taylor
3||Don't Shoot the Pianist|Episode 2 of "The Gunfighters".|The Doctor (First Doctor);Steven Taylor
3||Johnny Ringo|Episode 3 of "The Gunfighters".|The Doctor (First Doctor);Steven Taylor
3||The OK Corral|Episode 4 of "The Gunfighters".|The Doctor (First Doctor);Steven Taylor
3||The Savages: Episode 1|Episode 1 of "The Savages".|The Doctor (First Doctor);Steven Taylor
3||The Savages: Episode 2|Episode 2 of "The Savages".|The Doctor (First Doctor);Steven Taylor
3||The Savages: Episode 3|Episode 3 of "The Savages".|The Doctor (First Doctor);Steven Taylor
3||The Savages: Episode 4|Episode 4 of "The Savages".|The Doctor (First Doctor);Steven Taylor
3||The War Machines: Episode 1|Episode 1 of "The War Machines".|The Doctor (First Doctor);Ben Jackson;Polly
3||The War Machines: Episode 2|Episode 2 of "The War Machines".|The Doctor (First Doctor);Ben Jackson;Polly
3||The War Machines: Episode 3|Episode 3 of "The War Machines".|The Doctor (First Doctor);Ben Jackson;Polly
3||The War Machines: Episode 4|Episode 4 of "The War Machines".|The Doctor (First Doctor);Ben Jackson;Polly
4||The Smugglers: Part 1|Part 1 of "The Smugglers".|The Doctor (First Doctor);Ben Jackson;Polly
4||The Smugglers: Part 2|Part 2 of "The Smugglers".|The Doctor (First Doctor);Ben Jackson;Polly
4||The Smugglers: Part 3|Part 3 of "The Smugglers".|The Doctor (First Doctor);Ben Jackson;Polly
4||The Smugglers: Part 4|Part 4 of "The Smugglers".|The Doctor (First Doctor);Ben Jackson;Polly
4||The Tenth Planet: Part 1|Part 1 of "The Tenth Planet".|The Doctor (First Doctor);Ben Jackson;Polly
4||The Tenth Planet: Part 2|Part 2 of "The Tenth Planet".|The Doctor (First Doctor);Ben Jackson;Polly
4||The Tenth Planet: Part 3|Part 3 of "The Tenth Planet".|The Doctor (First Doctor);Ben Jackson;Polly
4||The Tenth Planet: Part 4|Part 4 of "The Tenth Planet".|The Doctor (First Doctor);Ben Jackson;Polly
4||The Power of the Daleks: Part 1|Part 1 of "The Power of the Daleks".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Power of the Daleks: Part 2|Part 2 of "The Power of the Daleks".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Power of the Daleks: Part 3|Part 3 of "The Power of the Daleks".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Power of the Daleks: Part 4|Part 4 of "The Power of the Daleks".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Power of the Daleks: Part 5|Part 5 of "The Power of the Daleks".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Power of the Daleks: Part 6|Part 6 of "The Power of the Daleks".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Highlanders: Part 1|Part 1 of "The Highlanders".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Highlanders: Part 2|Part 2 of "The Highlanders".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Highlanders: Part 3|Part 3 of "The Highlanders".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Highlanders: Part 4|Part 4 of "The Highlanders".|The Doctor (Second Doctor);Ben Jackson;Polly
4||The Underwater Menace: Part 1|Part 1 of "The Underwater Menace".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Underwater Menace: Part 2|Part 2 of "The Underwater Menace".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Underwater Menace: Part 3|Part 3 of "The Underwater Menace".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Underwater Menace: Part 4|Part 4 of "The Underwater Menace".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Moonbase: Part 1|Part 1 of "The Moonbase".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Moonbase: Part 2|Part 2 of "The Moonbase".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Moonbase: Part 3|Part 3 of "The Moonbase".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Moonbase: Part 4|Part 4 of "The Moonbase".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Macra Terror: Part 1|Part 1 of "The Macra Terror".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Macra Terror: Part 2|Part 2 of "The Macra Terror".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Macra Terror: Part 3|Part 3 of "The Macra Terror".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Macra Terror: Part 4|Part 4 of "The Macra Terror".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Faceless Ones: Part 1|Part 1 of "The Faceless Ones".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Faceless Ones: Part 2|Part 2 of "The Faceless Ones".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Faceless Ones: Part 3|Part 3 of "The Faceless Ones".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Faceless Ones: Part 4|Part 4 of "The Faceless Ones".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Faceless Ones: Part 5|Part 5 of "The Faceless Ones".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Faceless Ones: Part 6|Part 6 of "The Faceless Ones".|The Doctor (Second Doctor);Ben Jackson;Polly;Jamie McCrimmon
4||The Evil of the Daleks: Part 1|Part 1 of "The Evil of the Daleks".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
4||The Evil of the Daleks: Part 2|Part 2 of "The Evil of the Daleks".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
4||The Evil of the Daleks: Part 3|Part 3 of "The Evil of the Daleks".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
4||The Evil of the Daleks: Part 4|Part 4 of "The Evil of the Daleks".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
4||The Evil of the Daleks: Part 5|Part 5 of "The Evil of the Daleks".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
4||The Evil of the Daleks: Part 6|Part 6 of "The Evil of the Daleks".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
4||The Evil of the Daleks: Part 7|Part 7 of "The Evil of the Daleks".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Tomb of the Cybermen: Part 1|Part 1 of "The Tomb of the Cybermen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Tomb of the Cybermen: Part 2|Part 2 of "The Tomb of the Cybermen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Tomb of the Cybermen: Part 3|Part 3 of "The Tomb of the Cybermen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Tomb of the Cybermen: Part 4|Part 4 of "The Tomb of the Cybermen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Abominable Snowmen: Part 1|Part 1 of "The Abominable Snowmen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Abominable Snowmen: Part 2|Part 2 of "The Abominable Snowmen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Abominable Snowmen: Part 3|Part 3 of "The Abominable Snowmen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Abominable Snowmen: Part 4|Part 4 of "The Abominable Snowmen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Abominable Snowmen: Part 5|Part 5 of "The Abominable Snowmen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Abominable Snowmen: Part 6|Part 6 of "The Abominable Snowmen".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Ice Warriors: Part 1|Part 1 of "The Ice Warriors".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Ice Warriors: Part 2|Part 2 of "The Ice Warriors".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Ice Warriors: Part 3|Part 3 of "The Ice Warriors".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Ice Warriors: Part 4|Part 4 of "The Ice Warriors".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Ice Warriors: Part 5|Part 5 of "The Ice Warriors".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Ice Warriors: Part 6|Part 6 of "The Ice Warriors".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Enemy of the World: Part 1|Part 1 of "The Enemy of the World".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Enemy of the World: Part 2|Part 2 of "The Enemy of the World".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Enemy of the World: Part 3|Part 3 of "The Enemy of the World".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Enemy of the World: Part 4|Part 4 of "The Enemy of the World".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Enemy of the World: Part 5|Part 5 of "The Enemy of the World".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Enemy of the World: Part 6|Part 6 of "The Enemy of the World".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Web of Fear: Part 1|Part 1 of "The Web of Fear".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Web of Fear: Part 2|Part 2 of "The Web of Fear".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Web of Fear: Part 3|Part 3 of "The Web of Fear".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Web of Fear: Part 4|Part 4 of "The Web of Fear".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Web of Fear: Part 5|Part 5 of "The Web of Fear".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Web of Fear: Part 6|Part 6 of "The Web of Fear".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||Fury from the Deep: Part 1|Part 1 of "Fury from the Deep".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||Fury from the Deep: Part 2|Part 2 of "Fury from the Deep".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||Fury from the Deep: Part 3|Part 3 of "Fury from the Deep".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||Fury from the Deep: Part 4|Part 4 of "Fury from the Deep".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||Fury from the Deep: Part 5|Part 5 of "Fury from the Deep".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||Fury from the Deep: Part 6|Part 6 of "Fury from the Deep".|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5||The Wheel in Space: Part 1|Part 1 of "The Wheel in Space".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
5||The Wheel in Space: Part 2|Part 2 of "The Wheel in Space".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
5||The Wheel in Space: Part 3|Part 3 of "The Wheel in Space".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
5||The Wheel in Space: Part 4|Part 4 of "The Wheel in Space".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
5||The Wheel in Space: Part 5|Part 5 of "The Wheel in Space".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
5||The Wheel in Space: Part 6|Part 6 of "The Wheel in Space".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Dominators: Part 1|Part 1 of "The Dominators".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Dominators: Part 2|Part 2 of "The Dominators".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Dominators: Part 3|Part 3 of "The Dominators".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Dominators: Part 4|Part 4 of "The Dominators".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Dominators: Part 5|Part 5 of "The Dominators".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Mind Robber: Part 1|Part 1 of "The Mind Robber".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Mind Robber: Part 2|Part 2 of "The Mind Robber".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Mind Robber: Part 3|Part 3 of "The Mind Robber".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Mind Robber: Part 4|Part 4 of "The Mind Robber".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Mind Robber: Part 5|Part 5 of "The Mind Robber".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Invasion: Part 1|Part 1 of "The Invasion".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Invasion: Part 2|Part 2 of "The Invasion".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Invasion: Part 3|Part 3 of "The Invasion".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Invasion: Part 4|Part 4 of "The Invasion".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Invasion: Part 5|Part 5 of "The Invasion".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Invasion: Part 6|Part 6 of "The Invasion".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Invasion: Part 7|Part 7 of "The Invasion".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Invasion: Part 8|Part 8 of "The Invasion".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Krotons: Part 1|Part 1 of "The Krotons".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Krotons: Part 2|Part 2 of "The Krotons".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Krotons: Part 3|Part 3 of "The Krotons".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Krotons: Part 4|Part 4 of "The Krotons".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Seeds of Death: Part 1|Part 1 of "The Seeds of Death".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Seeds of Death: Part 2|Part 2 of "The Seeds of Death".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Seeds of Death: Part 3|Part 3 of "The Seeds of Death".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Seeds of Death: Part 4|Part 4 of "The Seeds of Death".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Seeds of Death: Part 5|Part 5 of "The Seeds of Death".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Seeds of Death: Part 6|Part 6 of "The Seeds of Death".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Space Pirates: Part 1|Part 1 of "The Space Pirates".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Space Pirates: Part 2|Part 2 of "The Space Pirates".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Space Pirates: Part 3|Part 3 of "The Space Pirates".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Space Pirates: Part 4|Part 4 of "The Space Pirates".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Space Pirates: Part 5|Part 5 of "The Space Pirates".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The Space Pirates: Part 6|Part 6 of "The Space Pirates".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 1|Part 1 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 2|Part 2 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 3|Part 3 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 4|Part 4 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 5|Part 5 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 6|Part 6 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 7|Part 7 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 8|Part 8 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 9|Part 9 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6||The War Games: Part 10|Part 10 of "The War Games".|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
7||Spearhead from Space: Part 1|Part 1 of "Spearhead from Space".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Spearhead from Space: Part 2|Part 2 of "Spearhead from Space".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Spearhead from Space: Part 3|Part 3 of "Spearhead from Space".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Spearhead from Space: Part 4|Part 4 of "Spearhead from Space".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Doctor Who and the Silurians: Part 1|Part 1 of "Doctor Who and the Silurians".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Doctor Who and the Silurians: Part 2|Part 2 of "Doctor Who and the Silurians".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Doctor Who and the Silurians: Part 3|Part 3 of "Doctor Who and the Silurians".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Doctor Who and the Silurians: Part 4|Part 4 of "Doctor Who and the Silurians".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Doctor Who and the Silurians: Part 5|Part 5 of "Doctor Who and the Silurians".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Doctor Who and the Silurians: Part 6|Part 6 of "Doctor Who and the Silurians".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Doctor Who and the Silurians: Part 7|Part 7 of "Doctor Who and the Silurians".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||The Ambassadors of Death: Part 1|Part 1 of "The Ambassadors of Death".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||The Ambassadors of Death: Part 2|Part 2 of "The Ambassadors of Death".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||The Ambassadors of Death: Part 3|Part 3 of "The Ambassadors of Death".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||The Ambassadors of Death: Part 4|Part 4 of "The Ambassadors of Death".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||The Ambassadors of Death: Part 5|Part 5 of "The Ambassadors of Death".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||The Ambassadors of Death: Part 6|Part 6 of "The Ambassadors of Death".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||The Ambassadors of Death: Part 7|Part 7 of "The Ambassadors of Death".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Inferno: Part 1|Part 1 of "Inferno".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Inferno: Part 2|Part 2 of "Inferno".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Inferno: Part 3|Part 3 of "Inferno".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Inferno: Part 4|Part 4 of "Inferno".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Inferno: Part 5|Part 5 of "Inferno".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Inferno: Part 6|Part 6 of "Inferno".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7||Inferno: Part 7|Part 7 of "Inferno".|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
8||Terror of the Autons: Part 1|Part 1 of "Terror of the Autons".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||Terror of the Autons: Part 2|Part 2 of "Terror of the Autons".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||Terror of the Autons: Part 3|Part 3 of "Terror of the Autons".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||Terror of the Autons: Part 4|Part 4 of "Terror of the Autons".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Mind of Evil: Part 1|Part 1 of "The Mind of Evil".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Mind of Evil: Part 2|Part 2 of "The Mind of Evil".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Mind of Evil: Part 3|Part 3 of "The Mind of Evil".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Mind of Evil: Part 4|Part 4 of "The Mind of Evil".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Mind of Evil: Part 5|Part 5 of "The Mind of Evil".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Mind of Evil: Part 6|Part 6 of "The Mind of Evil".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Claws of Axos: Part 1|Part 1 of "The Claws of Axos".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Claws of Axos: Part 2|Part 2 of "The Claws of Axos".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Claws of Axos: Part 3|Part 3 of "The Claws of Axos".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Claws of Axos: Part 4|Part 4 of "The Claws of Axos".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||Colony in Space: Part 1|Part 1 of "Colony in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||Colony in Space: Part 2|Part 2 of "Colony in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||Colony in Space: Part 3|Part 3 of "Colony in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||Colony in Space: Part 4|Part 4 of "Colony in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||Colony in Space: Part 5|Part 5 of "Colony in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||Colony in Space: Part 6|Part 6 of "Colony in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Dæmons: Part 1|Part 1 of "The Dæmons".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Dæmons: Part 2|Part 2 of "The Dæmons".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Dæmons: Part 3|Part 3 of "The Dæmons".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Dæmons: Part 4|Part 4 of "The Dæmons".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8||The Dæmons: Part 5|Part 5 of "The Dæmons".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||Day of the Daleks: Part 1|Part 1 of "Day of the Daleks".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||Day of the Daleks: Part 2|Part 2 of "Day of the Daleks".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||Day of the Daleks: Part 3|Part 3 of "Day of the Daleks".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||Day of the Daleks: Part 4|Part 4 of "Day of the Daleks".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Curse of Peladon: Part 1|Part 1 of "The Curse of Peladon".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Curse of Peladon: Part 2|Part 2 of "The Curse of Peladon".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Curse of Peladon: Part 3|Part 3 of "The Curse of Peladon".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Curse of Peladon: Part 4|Part 4 of "The Curse of Peladon".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Sea Devils: Part 1|Part 1 of "The Sea Devils".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Sea Devils: Part 2|Part 2 of "The Sea Devils".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Sea Devils: Part 3|Part 3 of "The Sea Devils".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Sea Devils: Part 4|Part 4 of "The Sea Devils".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Sea Devils: Part 5|Part 5 of "The Sea Devils".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Sea Devils: Part 6|Part 6 of "The Sea Devils".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Mutants: Part 1|Part 1 of "The Mutants".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Mutants: Part 2|Part 2 of "The Mutants".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Mutants: Part 3|Part 3 of "The Mutants".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Mutants: Part 4|Part 4 of "The Mutants".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Mutants: Part 5|Part 5 of "The Mutants".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Mutants: Part 6|Part 6 of "The Mutants".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Time Monster: Part 1|Part 1 of "The Time Monster".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Time Monster: Part 2|Part 2 of "The Time Monster".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Time Monster: Part 3|Part 3 of "The Time Monster".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Time Monster: Part 4|Part 4 of "The Time Monster".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Time Monster: Part 5|Part 5 of "The Time Monster".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9||The Time Monster: Part 6|Part 6 of "The Time Monster".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||The Three Doctors: Part 1|Part 1 of "The Three Doctors".|The Doctor (Third Doctor);The Doctor (Second Doctor);The Doctor (First Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||The Three Doctors: Part 2|Part 2 of "The Three Doctors".|The Doctor (Third Doctor);The Doctor (Second Doctor);The Doctor (First Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||The Three Doctors: Part 3|Part 3 of "The Three Doctors".|The Doctor (Third Doctor);The Doctor (Second Doctor);The Doctor (First Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||The Three Doctors: Part 4|Part 4 of "The Three Doctors".|The Doctor (Third Doctor);The Doctor (Second Doctor);The Doctor (First Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||Carnival of Monsters: Part 1|Part 1 of "Carnival of Monsters".|The Doctor (Third Doctor);Jo Grant
10||Carnival of Monsters: Part 2|Part 2 of "Carnival of Monsters".|The Doctor (Third Doctor);Jo Grant
10||Carnival of Monsters: Part 3|Part 3 of "Carnival of Monsters".|The Doctor (Third Doctor);Jo Grant
10||Carnival of Monsters: Part 4|Part 4 of "Carnival of Monsters".|The Doctor (Third Doctor);Jo Grant
10||Frontier in Space: Part 1|Part 1 of "Frontier in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||Frontier in Space: Part 2|Part 2 of "Frontier in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||Frontier in Space: Part 3|Part 3 of "Frontier in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||Frontier in Space: Part 4|Part 4 of "Frontier in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||Frontier in Space: Part 5|Part 5 of "Frontier in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||Frontier in Space: Part 6|Part 6 of "Frontier in Space".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||Planet of the Daleks: Part 1|Part 1 of "Planet of the Daleks".|The Doctor (Third Doctor);Jo Grant
10||Planet of the Daleks: Part 2|Part 2 of "Planet of the Daleks".|The Doctor (Third Doctor);Jo Grant
10||Planet of the Daleks: Part 3|Part 3 of "Planet of the Daleks".|The Doctor (Third Doctor);Jo Grant
10||Planet of the Daleks: Part 4|Part 4 of "Planet of the Daleks".|The Doctor (Third Doctor);Jo Grant
10||Planet of the Daleks: Part 5|Part 5 of "Planet of the Daleks".|The Doctor (Third Doctor);Jo Grant
10||Planet of the Daleks: Part 6|Part 6 of "Planet of the Daleks".|The Doctor (Third Doctor);Jo Grant
10||The Green Death: Part 1|Part 1 of "The Green Death".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||The Green Death: Part 2|Part 2 of "The Green Death".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||The Green Death: Part 3|Part 3 of "The Green Death".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||The Green Death: Part 4|Part 4 of "The Green Death".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||The Green Death: Part 5|Part 5 of "The Green Death".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10||The Green Death: Part 6|Part 6 of "The Green Death".|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
11||The Time Warrior: Part 1|Part 1 of "The Time Warrior".|The Doctor (Third Doctor);Sarah Jane Smith
11||The Time Warrior: Part 2|Part 2 of "The Time Warrior".|The Doctor (Third Doctor);Sarah Jane Smith
11||The Time Warrior: Part 3|Part 3 of "The Time Warrior".|The Doctor (Third Doctor);Sarah Jane Smith
11||The Time Warrior: Part 4|Part 4 of "The Time Warrior".|The Doctor (Third Doctor);Sarah Jane Smith
11||Invasion of the Dinosaurs: Part 1|Part 1 of "Invasion of the Dinosaurs".|The Doctor (Third Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart
11||Invasion of the Dinosaurs: Part 2|Part 2 of "Invasion of the Dinosaurs".|The Doctor (Third Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart
11||Invasion of the Dinosaurs: Part 3|Part 3 of "Invasion of the Dinosaurs".|The Doctor (Third Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart
11||Invasion of the Dinosaurs: Part 4|Part 4 of "Invasion of the Dinosaurs".|The Doctor (Third Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart
11||Invasion of the Dinosaurs: Part 5|Part 5 of "Invasion of the Dinosaurs".|The Doctor (Third Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart
11||Invasion of the Dinosaurs: Part 6|Part 6 of "Invasion of the Dinosaurs".|The Doctor (Third Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart
11||Death to the Daleks: Part 1|Part 1 of "Death to the Daleks".|The Doctor (Third Doctor);Sarah Jane Smith
11||Death to the Daleks: Part 2|Part 2 of "Death to the Daleks".|The Doctor (Third Doctor);Sarah Jane Smith
11||Death to the Daleks: Part 3|Part 3 of "Death to the Daleks".|The Doctor (Third Doctor);Sarah Jane Smith
11||Death to the Daleks: Part 4|Part 4 of "Death to the Daleks".|The Doctor (Third Doctor);Sarah Jane Smith
11||The Monster of Peladon: Part 1|Part 1 of "The Monster of Peladon".|The Doctor (Third Doctor);Sarah Jane Smith
11||The Monster of Peladon: Part 2|Part 2 of "The Monster of Peladon".|The Doctor (Third Doctor);Sarah Jane Smith
11||The Monster of Peladon: Part 3|Part 3 of "The Monster of Peladon".|The Doctor (Third Doctor);Sarah Jane Smith
11||The Monster of Peladon: Part 4|Part 4 of "The Monster of Peladon".|The Doctor (Third Doctor);Sarah Jane Smith
11||The Monster of Peladon: Part 5|Part 5 of "The Monster of Peladon".|The Doctor (Third Doctor);Sarah Jane Smith
11||The Monster of Peladon: Part 6|Part 6 of "The Monster of Peladon".|The Doctor (Third Doctor);Sarah Jane Smith
11||Planet of the Spiders: Part 1|Part 1 of "Planet of the Spiders".|The Doctor (Third Doctor);Sarah Jane Smith
11||Planet of the Spiders: Part 2|Part 2 of "Planet of the Spiders".|The Doctor (Third Doctor);Sarah Jane Smith
11||Planet of the Spiders: Part 3|Part 3 of "Planet of the Spiders".|The Doctor (Third Doctor);Sarah Jane Smith
11||Planet of the Spiders: Part 4|Part 4 of "Planet of the Spiders".|The Doctor (Third Doctor);Sarah Jane Smith
11||Planet of the Spiders: Part 5|Part 5 of "Planet of the Spiders".|The Doctor (Third Doctor);Sarah Jane Smith
11||Planet of the Spiders: Part 6|Part 6 of "Planet of the Spiders".|The Doctor (Third Doctor);Sarah Jane Smith
12||Robot: Part 1|Part 1 of "Robot".|The Doctor (Fourth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Harry Sullivan
12||Robot: Part 2|Part 2 of "Robot".|The Doctor (Fourth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Harry Sullivan
12||Robot: Part 3|Part 3 of "Robot".|The Doctor (Fourth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Harry Sullivan
12||Robot: Part 4|Part 4 of "Robot".|The Doctor (Fourth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Harry Sullivan
12||The Ark in Space: Part 1|Part 1 of "The Ark in Space".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||The Ark in Space: Part 2|Part 2 of "The Ark in Space".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||The Ark in Space: Part 3|Part 3 of "The Ark in Space".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||The Ark in Space: Part 4|Part 4 of "The Ark in Space".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||The Sontaran Experiment: Part 1|Part 1 of "The Sontaran Experiment".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||The Sontaran Experiment: Part 2|Part 2 of "The Sontaran Experiment".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Genesis of the Daleks: Part 1|Part 1 of "Genesis of the Daleks".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Genesis of the Daleks: Part 2|Part 2 of "Genesis of the Daleks".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Genesis of the Daleks: Part 3|Part 3 of "Genesis of the Daleks".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Genesis of the Daleks: Part 4|Part 4 of "Genesis of the Daleks".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Genesis of the Daleks: Part 5|Part 5 of "Genesis of the Daleks".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Genesis of the Daleks: Part 6|Part 6 of "Genesis of the Daleks".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Revenge of the Cybermen: Part 1|Part 1 of "Revenge of the Cybermen".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Revenge of the Cybermen: Part 2|Part 2 of "Revenge of the Cybermen".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Revenge of the Cybermen: Part 3|Part 3 of "Revenge of the Cybermen".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
12||Revenge of the Cybermen: Part 4|Part 4 of "Revenge of the Cybermen".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
13||Terror of the Zygons: Part 1|Part 1 of "Terror of the Zygons".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan;Brigadier Lethbridge-Stewart
13||Terror of the Zygons: Part 2|Part 2 of "Terror of the Zygons".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan;Brigadier Lethbridge-Stewart
13||Terror of the Zygons: Part 3|Part 3 of "Terror of the Zygons".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan;Brigadier Lethbridge-Stewart
13||Terror of the Zygons: Part 4|Part 4 of "Terror of the Zygons".|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan;Brigadier Lethbridge-Stewart
13||Planet of Evil: Part 1|Part 1 of "Planet of Evil".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||Planet of Evil: Part 2|Part 2 of "Planet of Evil".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||Planet of Evil: Part 3|Part 3 of "Planet of Evil".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||Planet of Evil: Part 4|Part 4 of "Planet of Evil".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||Pyramids of Mars: Part 1|Part 1 of "Pyramids of Mars".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||Pyramids of Mars: Part 2|Part 2 of "Pyramids of Mars".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||Pyramids of Mars: Part 3|Part 3 of "Pyramids of Mars".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||Pyramids of Mars: Part 4|Part 4 of "Pyramids of Mars".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Android Invasion: Part 1|Part 1 of "The Android Invasion".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Android Invasion: Part 2|Part 2 of "The Android Invasion".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Android Invasion: Part 3|Part 3 of "The Android Invasion".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Android Invasion: Part 4|Part 4 of "The Android Invasion".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Brain of Morbius: Part 1|Part 1 of "The Brain of Morbius".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Brain of Morbius: Part 2|Part 2 of "The Brain of Morbius".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Brain of Morbius: Part 3|Part 3 of "The Brain of Morbius".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Brain of Morbius: Part 4|Part 4 of "The Brain of Morbius".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Seeds of Doom: Part 1|Part 1 of "The Seeds of Doom".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Seeds of Doom: Part 2|Part 2 of "The Seeds of Doom".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Seeds of Doom: Part 3|Part 3 of "The Seeds of Doom".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Seeds of Doom: Part 4|Part 4 of "The Seeds of Doom".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Seeds of Doom: Part 5|Part 5 of "The Seeds of Doom".|The Doctor (Fourth Doctor);Sarah Jane Smith
13||The Seeds of Doom: Part 6|Part 6 of "The Seeds of Doom".|The Doctor (Fourth Doctor);Sarah Jane Smith
14||The Masque of Mandragora: Part 1|Part 1 of "The Masque of Mandragora".|The Doctor (Fourth Doctor);Sarah Jane Smith
14||The Masque of Mandragora: Part 2|Part 2 of "The Masque of Mandragora".|The Doctor (Fourth Doctor);Sarah Jane Smith
14||The Masque of Mandragora: Part 3|Part 3 of "The Masque of Mandragora".|The Doctor (Fourth Doctor);Sarah Jane Smith
14||The Masque of Mandragora: Part 4|Part 4 of "The Masque of Mandragora".|The Doctor (Fourth Doctor);Sarah Jane Smith
14||The Hand of Fear: Part 1|Part 1 of "The Hand of Fear".|The Doctor (Fourth Doctor);Sarah Jane Smith
14||The Hand of Fear: Part 2|Part 2 of "The Hand of Fear".|The Doctor (Fourth Doctor);Sarah Jane Smith
14||The Hand of Fear: Part 3|Part 3 of "The Hand of Fear".|The Doctor (Fourth Doctor);Sarah Jane Smith
14||The Hand of Fear: Part 4|Part 4 of "The Hand of Fear".|The Doctor (Fourth Doctor);Sarah Jane Smith
14||The Deadly Assassin: Part 1|Part 1 of "The Deadly Assassin".|The Doctor (Fourth Doctor)
14||The Deadly Assassin: Part 2|Part 2 of "The Deadly Assassin".|The Doctor (Fourth Doctor)
14||The Deadly Assassin: Part 3|Part 3 of "The Deadly Assassin".|The Doctor (Fourth Doctor)
14||The Deadly Assassin: Part 4|Part 4 of "The Deadly Assassin".|The Doctor (Fourth Doctor)
14||The Face of Evil: Part 1|Part 1 of "The Face of Evil".|The Doctor (Fourth Doctor);Leela
14||The Face of Evil: Part 2|Part 2 of "The Face of Evil".|The Doctor (Fourth Doctor);Leela
14||The Face of Evil: Part 3|Part 3 of "The Face of Evil".|The Doctor (Fourth Doctor);Leela
14||The Face of Evil: Part 4|Part 4 of "The Face of Evil".|The Doctor (Fourth Doctor);Leela
14||The Robots of Death: Part 1|Part 1 of "The Robots of Death".|The Doctor (Fourth Doctor);Leela
14||The Robots of Death: Part 2|Part 2 of "The Robots of Death".|The Doctor (Fourth Doctor);Leela
14||The Robots of Death: Part 3|Part 3 of "The Robots of Death".|The Doctor (Fourth Doctor);Leela
14||The Robots of Death: Part 4|Part 4 of "The Robots of Death".|The Doctor (Fourth Doctor);Leela
14||The Talons of Weng-Chiang: Part 1|Part 1 of "The Talons of Weng-Chiang".|The Doctor (Fourth Doctor);Leela
14||The Talons of Weng-Chiang: Part 2|Part 2 of "The Talons of Weng-Chiang".|The Doctor (Fourth Doctor);Leela
14||The Talons of Weng-Chiang: Part 3|Part 3 of "The Talons of Weng-Chiang".|The Doctor (Fourth Doctor);Leela
14||The Talons of Weng-Chiang: Part 4|Part 4 of "The Talons of Weng-Chiang".|The Doctor (Fourth Doctor);Leela
14||The Talons of Weng-Chiang: Part 5|Part 5 of "The Talons of Weng-Chiang".|The Doctor (Fourth Doctor);Leela
14||The Talons of Weng-Chiang: Part 6|Part 6 of "The Talons of Weng-Chiang".|The Doctor (Fourth Doctor);Leela
15||Horror of Fang Rock: Part 1|Part 1 of "Horror of Fang Rock".|The Doctor (Fourth Doctor);Leela
15||Horror of Fang Rock: Part 2|Part 2 of "Horror of Fang Rock".|The Doctor (Fourth Doctor);Leela
15||Horror of Fang Rock: Part 3|Part 3 of "Horror of Fang Rock".|The Doctor (Fourth Doctor);Leela
15||Horror of Fang Rock: Part 4|Part 4 of "Horror of Fang Rock".|The Doctor (Fourth Doctor);Leela
15||The Invisible Enemy: Part 1|Part 1 of "The Invisible Enemy".|The Doctor (Fourth Doctor);Leela;K9
15||The Invisible Enemy: Part 2|Part 2 of "The Invisible Enemy".|The Doctor (Fourth Doctor);Leela;K9
15||The Invisible Enemy: Part 3|Part 3 of "The Invisible Enemy".|The Doctor (Fourth Doctor);Leela;K9
15||The Invisible Enemy: Part 4|Part 4 of "The Invisible Enemy".|The Doctor (Fourth Doctor);Leela;K9
15||Image of the Fendahl: Part 1|Part 1 of "Image of the Fendahl".|The Doctor (Fourth Doctor);Leela;K9
15||Image of the Fendahl: Part 2|Part 2 of "Image of the Fendahl".|The Doctor (Fourth Doctor);Leela;K9
15||Image of the Fendahl: Part 3|Part 3 of "Image of the Fendahl".|The Doctor (Fourth Doctor);Leela;K9
15||Image of the Fendahl: Part 4|Part 4 of "Image of the Fendahl".|The Doctor (Fourth Doctor);Leela;K9
15||The Sun Makers: Part 1|Part 1 of "The Sun Makers".|The Doctor (Fourth Doctor);Leela;K9
15||The Sun Makers: Part 2|Part 2 of "The Sun Makers".|The Doctor (Fourth Doctor);Leela;K9
15||The Sun Makers: Part 3|Part 3 of "The Sun Makers".|The Doctor (Fourth Doctor);Leela;K9
15||The Sun Makers: Part 4|Part 4 of "The Sun Makers".|The Doctor (Fourth Doctor);Leela;K9
15||Underworld: Part 1|Part 1 of "Underworld".|The Doctor (Fourth Doctor);Leela;K9
15||Underworld: Part 2|Part 2 of "Underworld".|The Doctor (Fourth Doctor);Leela;K9
15||Underworld: Part 3|Part 3 of "Underworld".|The Doctor (Fourth Doctor);Leela;K9
15||Underworld: Part 4|Part 4 of "Underworld".|The Doctor (Fourth Doctor);Leela;K9
15||The Invasion of Time: Part 1|Part 1 of "The Invasion of Time".|The Doctor (Fourth Doctor);Leela;K9
15||The Invasion of Time: Part 2|Part 2 of "The Invasion of Time".|The Doctor (Fourth Doctor);Leela;K9
15||The Invasion of Time: Part 3|Part 3 of "The Invasion of Time".|The Doctor (Fourth Doctor);Leela;K9
15||The Invasion of Time: Part 4|Part 4 of "The Invasion of Time".|The Doctor (Fourth Doctor);Leela;K9
15||The Invasion of Time: Part 5|Part 5 of "The Invasion of Time".|The Doctor (Fourth Doctor);Leela;K9
15||The Invasion of Time: Part 6|Part 6 of "The Invasion of Time".|The Doctor (Fourth Doctor);Leela;K9
16||The Ribos Operation: Part 1|Part 1 of "The Ribos Operation".|The Doctor (Fourth Doctor);Romana I;K9
16||The Ribos Operation: Part 2|Part 2 of "The Ribos Operation".|The Doctor (Fourth Doctor);Romana I;K9
16||The Ribos Operation: Part 3|Part 3 of "The Ribos Operation".|The Doctor (Fourth Doctor);Romana I;K9
16||The Ribos Operation: Part 4|Part 4 of "The Ribos Operation".|The Doctor (Fourth Doctor);Romana I;K9
16||The Pirate Planet: Part 1|Part 1 of "The Pirate Planet".|The Doctor (Fourth Doctor);Romana I;K9
16||The Pirate Planet: Part 2|Part 2 of "The Pirate Planet".|The Doctor (Fourth Doctor);Romana I;K9
16||The Pirate Planet: Part 3|Part 3 of "The Pirate Planet".|The Doctor (Fourth Doctor);Romana I;K9
16||The Pirate Planet: Part 4|Part 4 of "The Pirate Planet".|The Doctor (Fourth Doctor);Romana I;K9
16||The Stones of Blood: Part 1|Part 1 of "The Stones of Blood".|The Doctor (Fourth Doctor);Romana I;K9
16||The Stones of Blood: Part 2|Part 2 of "The Stones of Blood".|The Doctor (Fourth Doctor);Romana I;K9
16||The Stones of Blood: Part 3|Part 3 of "The Stones of Blood".|The Doctor (Fourth Doctor);Romana I;K9
16||The Stones of Blood: Part 4|Part 4 of "The Stones of Blood".|The Doctor (Fourth Doctor);Romana I;K9
16||The Androids of Tara: Part 1|Part 1 of "The Androids of Tara".|The Doctor (Fourth Doctor);Romana I;K9
16||The Androids of Tara: Part 2|Part 2 of "The Androids of Tara".|The Doctor (Fourth Doctor);Romana I;K9
16||The Androids of Tara: Part 3|Part 3 of "The Androids of Tara".|The Doctor (Fourth Doctor);Romana I;K9
16||The Androids of Tara: Part 4|Part 4 of "The Androids of Tara".|The Doctor (Fourth Doctor);Romana I;K9
16||The Power of Kroll: Part 1|Part 1 of "The Power of Kroll".|The Doctor (Fourth Doctor);Romana I;K9
16||The Power of Kroll: Part 2|Part 2 of "The Power of Kroll".|The Doctor (Fourth Doctor);Romana I;K9
16||The Power of Kroll: Part 3|Part 3 of "The Power of Kroll".|The Doctor (Fourth Doctor);Romana I;K9
16||The Power of Kroll: Part 4|Part 4 of "The Power of Kroll".|The Doctor (Fourth Doctor);Romana I;K9
16||The Armageddon Factor: Part 1|Part 1 of "The Armageddon Factor".|The Doctor (Fourth Doctor);Romana I;K9
16||The Armageddon Factor: Part 2|Part 2 of "The Armageddon Factor".|The Doctor (Fourth Doctor);Romana I;K9
16||The Armageddon Factor: Part 3|Part 3 of "The Armageddon Factor".|The Doctor (Fourth Doctor);Romana I;K9
16||The Armageddon Factor: Part 4|Part 4 of "The Armageddon Factor".|The Doctor (Fourth Doctor);Romana I;K9
16||The Armageddon Factor: Part 5|Part 5 of "The Armageddon Factor".|The Doctor (Fourth Doctor);Romana I;K9
16||The Armageddon Factor: Part 6|Part 6 of "The Armageddon Factor".|The Doctor (Fourth Doctor);Romana I;K9
17||Destiny of the Daleks: Part 1|Part 1 of "Destiny of the Daleks".|The Doctor (Fourth Doctor);Romana II;K9
17||Destiny of the Daleks: Part 2|Part 2 of "Destiny of the Daleks".|The Doctor (Fourth Doctor);Romana II;K9
17||Destiny of the Daleks: Part 3|Part 3 of "Destiny of the Daleks".|The Doctor (Fourth Doctor);Romana II;K9
17||Destiny of the Daleks: Part 4|Part 4 of "Destiny of the Daleks".|The Doctor (Fourth Doctor);Romana II;K9
17||City of Death: Part 1|Part 1 of "City of Death".|The Doctor (Fourth Doctor);Romana II;K9
17||City of Death: Part 2|Part 2 of "City of Death".|The Doctor (Fourth Doctor);Romana II;K9
17||City of Death: Part 3|Part 3 of "City of Death".|The Doctor (Fourth Doctor);Romana II;K9
17||City of Death: Part 4|Part 4 of "City of Death".|The Doctor (Fourth Doctor);Romana II;K9
17||The Creature from the Pit: Part 1|Part 1 of "The Creature from the Pit".|The Doctor (Fourth Doctor);Romana II;K9
17||The Creature from the Pit: Part 2|Part 2 of "The Creature from the Pit".|The Doctor (Fourth Doctor);Romana II;K9
17||The Creature from the Pit: Part 3|Part 3 of "The Creature from the Pit".|The Doctor (Fourth Doctor);Romana II;K9
17||The Creature from the Pit: Part 4|Part 4 of "The Creature from the Pit".|The Doctor (Fourth Doctor);Romana II;K9
17||Nightmare of Eden: Part 1|Part 1 of "Nightmare of Eden".|The Doctor (Fourth Doctor);Romana II;K9
17||Nightmare of Eden: Part 2|Part 2 of "Nightmare of Eden".|The Doctor (Fourth Doctor);Romana II;K9
17||Nightmare of Eden: Part 3|Part 3 of "Nightmare of Eden".|The Doctor (Fourth Doctor);Romana II;K9
17||Nightmare of Eden: Part 4|Part 4 of "Nightmare of Eden".|The Doctor (Fourth Doctor);Romana II;K9
17||The Horns of Nimon: Part 1|Part 1 of "The Horns of Nimon".|The Doctor (Fourth Doctor);Romana II;K9
17||The Horns of Nimon: Part 2|Part 2 of "The Horns of Nimon".|The Doctor (Fourth Doctor);Romana II;K9
17||The Horns of Nimon: Part 3|Part 3 of "The Horns of Nimon".|The Doctor (Fourth Doctor);Romana II;K9
17||The Horns of Nimon: Part 4|Part 4 of "The Horns of Nimon".|The Doctor (Fourth Doctor);Romana II;K9
17||Shada: Part 1|Part 1 of "Shada".|The Doctor (Fourth Doctor);Romana II;K9
17||Shada: Part 2|Part 2 of "Shada".|The Doctor (Fourth Doctor);Romana II;K9
17||Shada: Part 3|Part 3 of "Shada".|The Doctor (Fourth Doctor);Romana II;K9
17||Shada: Part 4|Part 4 of "Shada".|The Doctor (Fourth Doctor);Romana II;K9
17||Shada: Part 5|Part 5 of "Shada".|The Doctor (Fourth Doctor);Romana II;K9
17||Shada: Part 6|Part 6 of "Shada".|The Doctor (Fourth Doctor);Romana II;K9
18||The Leisure Hive: Part 1|Part 1 of "The Leisure Hive".|The Doctor (Fourth Doctor);Romana II;K9
18||The Leisure Hive: Part 2|Part 2 of "The Leisure Hive".|The Doctor (Fourth Doctor);Romana II;K9
18||The Leisure Hive: Part 3|Part 3 of "The Leisure Hive".|The Doctor (Fourth Doctor);Romana II;K9
18||The Leisure Hive: Part 4|Part 4 of "The Leisure Hive".|The Doctor (Fourth Doctor);Romana II;K9
18||Meglos: Part 1|Part 1 of "Meglos".|The Doctor (Fourth Doctor);Romana II;K9
18||Meglos: Part 2|Part 2 of "Meglos".|The Doctor (Fourth Doctor);Romana II;K9
18||Meglos: Part 3|Part 3 of "Meglos".|The Doctor (Fourth Doctor);Romana II;K9
18||Meglos: Part 4|Part 4 of "Meglos".|The Doctor (Fourth Doctor);Romana II;K9
18||Full Circle: Part 1|Part 1 of "Full Circle".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||Full Circle: Part 2|Part 2 of "Full Circle".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||Full Circle: Part 3|Part 3 of "Full Circle".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||Full Circle: Part 4|Part 4 of "Full Circle".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||State of Decay: Part 1|Part 1 of "State of Decay".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||State of Decay: Part 2|Part 2 of "State of Decay".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||State of Decay: Part 3|Part 3 of "State of Decay".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||State of Decay: Part 4|Part 4 of "State of Decay".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||Warriors' Gate: Part 1|Part 1 of "Warriors' Gate".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||Warriors' Gate: Part 2|Part 2 of "Warriors' Gate".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||Warriors' Gate: Part 3|Part 3 of "Warriors' Gate".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||Warriors' Gate: Part 4|Part 4 of "Warriors' Gate".|The Doctor (Fourth Doctor);Romana II;K9;Adric
18||The Keeper of Traken: Part 1|Part 1 of "The Keeper of Traken".|The Doctor (Fourth Doctor);Adric;Nyssa
18||The Keeper of Traken: Part 2|Part 2 of "The Keeper of Traken".|The Doctor (Fourth Doctor);Adric;Nyssa
18||The Keeper of Traken: Part 3|Part 3 of "The Keeper of Traken".|The Doctor (Fourth Doctor);Adric;Nyssa
18||The Keeper of Traken: Part 4|Part 4 of "The Keeper of Traken".|The Doctor (Fourth Doctor);Adric;Nyssa
18||Logopolis: Part 1|Part 1 of "Logopolis".|The Doctor (Fourth Doctor);Adric;Nyssa;Tegan Jovanka
18||Logopolis: Part 2|Part 2 of "Logopolis".|The Doctor (Fourth Doctor);Adric;Nyssa;Tegan Jovanka
18||Logopolis: Part 3|Part 3 of "Logopolis".|The Doctor (Fourth Doctor);Adric;Nyssa;Tegan Jovanka
18||Logopolis: Part 4|Part 4 of "Logopolis".|The Doctor (Fourth Doctor);Adric;Nyssa;Tegan Jovanka
19||Castrovalva: Part 1|Part 1 of "Castrovalva".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Castrovalva: Part 2|Part 2 of "Castrovalva".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Castrovalva: Part 3|Part 3 of "Castrovalva".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Castrovalva: Part 4|Part 4 of "Castrovalva".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Four to Doomsday: Part 1|Part 1 of "Four to Doomsday".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Four to Doomsday: Part 2|Part 2 of "Four to Doomsday".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Four to Doomsday: Part 3|Part 3 of "Four to Doomsday".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Four to Doomsday: Part 4|Part 4 of "Four to Doomsday".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Kinda: Part 1|Part 1 of "Kinda".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Kinda: Part 2|Part 2 of "Kinda".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Kinda: Part 3|Part 3 of "Kinda".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Kinda: Part 4|Part 4 of "Kinda".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||The Visitation: Part 1|Part 1 of "The Visitation".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||The Visitation: Part 2|Part 2 of "The Visitation".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||The Visitation: Part 3|Part 3 of "The Visitation".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||The Visitation: Part 4|Part 4 of "The Visitation".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Black Orchid: Part 1|Part 1 of "Black Orchid".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Black Orchid: Part 2|Part 2 of "Black Orchid".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Earthshock: Part 1|Part 1 of "Earthshock".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Earthshock: Part 2|Part 2 of "Earthshock".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Earthshock: Part 3|Part 3 of "Earthshock".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Earthshock: Part 4|Part 4 of "Earthshock".|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19||Time-Flight: Part 1|Part 1 of "Time-Flight".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
19||Time-Flight: Part 2|Part 2 of "Time-Flight".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
19||Time-Flight: Part 3|Part 3 of "Time-Flight".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
19||Time-Flight: Part 4|Part 4 of "Time-Flight".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20||Arc of Infinity: Part 1|Part 1 of "Arc of Infinity".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20||Arc of Infinity: Part 2|Part 2 of "Arc of Infinity".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20||Arc of Infinity: Part 3|Part 3 of "Arc of Infinity".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20||Arc of Infinity: Part 4|Part 4 of "Arc of Infinity".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20||Snakedance: Part 1|Part 1 of "Snakedance".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20||Snakedance: Part 2|Part 2 of "Snakedance".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20||Snakedance: Part 3|Part 3 of "Snakedance".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20||Snakedance: Part 4|Part 4 of "Snakedance".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20||Mawdryn Undead: Part 1|Part 1 of "Mawdryn Undead".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka;Vislor Turlough
20||Mawdryn Undead: Part 2|Part 2 of "Mawdryn Undead".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka;Vislor Turlough
20||Mawdryn Undead: Part 3|Part 3 of "Mawdryn Undead".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka;Vislor Turlough
20||Mawdryn Undead: Part 4|Part 4 of "Mawdryn Undead".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka;Vislor Turlough
20||Terminus: Part 1|Part 1 of "Terminus".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka;Vislor Turlough
20||Terminus: Part 2|Part 2 of "Terminus".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka;Vislor Turlough
20||Terminus: Part 3|Part 3 of "Terminus".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka;Vislor Turlough
20||Terminus: Part 4|Part 4 of "Terminus".|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka;Vislor Turlough
20||Enlightenment: Part 1|Part 1 of "Enlightenment".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
20||Enlightenment: Part 2|Part 2 of "Enlightenment".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
20||Enlightenment: Part 3|Part 3 of "Enlightenment".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
20||Enlightenment: Part 4|Part 4 of "Enlightenment".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
20||The King's Demons: Part 1|Part 1 of "The King's Demons".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
20||The King's Demons: Part 2|Part 2 of "The King's Demons".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
20||The Five Doctors: Part 1|Part 1 of "The Five Doctors".|The Doctor (First Doctor);The Doctor (Second Doctor);The Doctor (Third Doctor);The Doctor (Fourth Doctor);The Doctor (Fifth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Tegan Jovanka;Vislor Turlough
20||The Five Doctors: Part 2|Part 2 of "The Five Doctors".|The Doctor (First Doctor);The Doctor (Second Doctor);The Doctor (Third Doctor);The Doctor (Fourth Doctor);The Doctor (Fifth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Tegan Jovanka;Vislor Turlough
20||The Five Doctors: Part 3|Part 3 of "The Five Doctors".|The Doctor (First Doctor);The Doctor (Second Doctor);The Doctor (Third Doctor);The Doctor (Fourth Doctor);The Doctor (Fifth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Tegan Jovanka;Vislor Turlough
20||The Five Doctors: Part 4|Part 4 of "The Five Doctors".|The Doctor (First Doctor);The Doctor (Second Doctor);The Doctor (Third Doctor);The Doctor (Fourth Doctor);The Doctor (Fifth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Tegan Jovanka;Vislor Turlough
20||The Five Doctors: Part 5|Part 5 of "The Five Doctors".|The Doctor (First Doctor);The Doctor (Second Doctor);The Doctor (Third Doctor);The Doctor (Fourth Doctor);The Doctor (Fifth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Tegan Jovanka;Vislor Turlough
20||The Five Doctors: Part 6|Part 6 of "The Five Doctors".|The Doctor (First Doctor);The Doctor (Second Doctor);The Doctor (Third Doctor);The Doctor (Fourth Doctor);The Doctor (Fifth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Tegan Jovanka;Vislor Turlough
21||Warriors of the Deep: Part 1|Part 1 of "Warriors of the Deep".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Warriors of the Deep: Part 2|Part 2 of "Warriors of the Deep".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Warriors of the Deep: Part 3|Part 3 of "Warriors of the Deep".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Warriors of the Deep: Part 4|Part 4 of "Warriors of the Deep".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||The Awakening: Part 1|Part 1 of "The Awakening".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||The Awakening: Part 2|Part 2 of "The Awakening".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Frontios: Part 1|Part 1 of "Frontios".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Frontios: Part 2|Part 2 of "Frontios".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Frontios: Part 3|Part 3 of "Frontios".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Frontios: Part 4|Part 4 of "Frontios".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Resurrection of the Daleks: Part 1|Part 1 of "Resurrection of the Daleks".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Resurrection of the Daleks: Part 2|Part 2 of "Resurrection of the Daleks".|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21||Planet of Fire: Part 1|Part 1 of "Planet of Fire".|The Doctor (Fifth Doctor);Vislor Turlough;Peri Brown
21||Planet of Fire: Part 2|Part 2 of "Planet of Fire".|The Doctor (Fifth Doctor);Vislor Turlough;Peri Brown
21||Planet of Fire: Part 3|Part 3 of "Planet of Fire".|The Doctor (Fifth Doctor);Vislor Turlough;Peri Brown
21||Planet of Fire: Part 4|Part 4 of "Planet of Fire".|The Doctor (Fifth Doctor);Vislor Turlough;Peri Brown
21||The Caves of Androzani: Part 1|Part 1 of "The Caves of Androzani".|The Doctor (Fifth Doctor);Peri Brown
21||The Caves of Androzani: Part 2|Part 2 of "The Caves of Androzani".|The Doctor (Fifth Doctor);Peri Brown
21||The Caves of Androzani: Part 3|Part 3 of "The Caves of Androzani".|The Doctor (Fifth Doctor);Peri Brown
21||The Caves of Androzani: Part 4|Part 4 of "The Caves of Androzani".|The Doctor (Fifth Doctor);Peri Brown
21||The Twin Dilemma: Part 1|Part 1 of "The Twin Dilemma".|The Doctor (Sixth Doctor);Peri Brown
21||The Twin Dilemma: Part 2|Part 2 of "The Twin Dilemma".|The Doctor (Sixth Doctor);Peri Brown
21||The Twin Dilemma: Part 3|Part 3 of "The Twin Dilemma".|The Doctor (Sixth Doctor);Peri Brown
21||The Twin Dilemma: Part 4|Part 4 of "The Twin Dilemma".|The Doctor (Sixth Doctor);Peri Brown
22||Attack of the Cybermen: Part 1|Part 1 of "Attack of the Cybermen".|The Doctor (Sixth Doctor);Peri Brown
22||Attack of the Cybermen: Part 2|Part 2 of "Attack of the Cybermen".|The Doctor (Sixth Doctor);Peri Brown
22||Vengeance on Varos: Part 1|Part 1 of "Vengeance on Varos".|The Doctor (Sixth Doctor);Peri Brown
22||Vengeance on Varos: Part 2|Part 2 of "Vengeance on Varos".|The Doctor (Sixth Doctor);Peri Brown
22||The Mark of the Rani: Part 1|Part 1 of "The Mark of the Rani".|The Doctor (Sixth Doctor);Peri Brown
22||The Mark of the Rani: Part 2|Part 2 of "The Mark of the Rani".|The Doctor (Sixth Doctor);Peri Brown
22||The Two Doctors: Part 1|Part 1 of "The Two Doctors".|The Doctor (Sixth Doctor);Peri Brown;The Doctor (Second Doctor);Jamie McCrimmon
22||The Two Doctors: Part 2|Part 2 of "The Two Doctors".|The Doctor (Sixth Doctor);Peri Brown;The Doctor (Second Doctor);Jamie McCrimmon
22||The Two Doctors: Part 3|Part 3 of "The Two Doctors".|The Doctor (Sixth Doctor);Peri Brown;The Doctor (Second Doctor);Jamie McCrimmon
22||Timelash: Part 1|Part 1 of "Timelash".|The Doctor (Sixth Doctor);Peri Brown
22||Timelash: Part 2|Part 2 of "Timelash".|The Doctor (Sixth Doctor);Peri Brown
22||Revelation of the Daleks: Part 1|Part 1 of "Revelation of the Daleks".|The Doctor (Sixth Doctor);Peri Brown
22||Revelation of the Daleks: Part 2|Part 2 of "Revelation of the Daleks".|The Doctor (Sixth Doctor);Peri Brown
23||The Mysterious Planet: Part 1|Part 1 of "The Mysterious Planet".|The Doctor (Sixth Doctor);Peri Brown
23||The Mysterious Planet: Part 2|Part 2 of "The Mysterious Planet".|The Doctor (Sixth Doctor);Peri Brown
23||The Mysterious Planet: Part 3|Part 3 of "The Mysterious Planet".|The Doctor (Sixth Doctor);Peri Brown
23||The Mysterious Planet: Part 4|Part 4 of "The Mysterious Planet".|The Doctor (Sixth Doctor);Peri Brown
23||Mindwarp: Part 1|Part 1 of "Mindwarp".|The Doctor (Sixth Doctor);Peri Brown
23||Mindwarp: Part 2|Part 2 of "Mindwarp".|The Doctor (Sixth Doctor);Peri Brown
23||Mindwarp: Part 3|Part 3 of "Mindwarp".|The Doctor (Sixth Doctor);Peri Brown
23||Mindwarp: Part 4|Part 4 of "Mindwarp".|The Doctor (Sixth Doctor);Peri Brown
23||Terror of the Vervoids: Part 1|Part 1 of "Terror of the Vervoids".|The Doctor (Sixth Doctor);Mel Bush
23||Terror of the Vervoids: Part 2|Part 2 of "Terror of the Vervoids".|The Doctor (Sixth Doctor);Mel Bush
23||Terror of the Vervoids: Part 3|Part 3 of "Terror of the Vervoids".|The Doctor (Sixth Doctor);Mel Bush
23||Terror of the Vervoids: Part 4|Part 4 of "Terror of the Vervoids".|The Doctor (Sixth Doctor);Mel Bush
23||The Ultimate Foe: Part 1|Part 1 of "The Ultimate Foe".|The Doctor (Sixth Doctor);Mel Bush
23||The Ultimate Foe: Part 2|Part 2 of "The Ultimate Foe".|The Doctor (Sixth Doctor);Mel Bush
24||Time and the Rani: Part 1|Part 1 of "Time and the Rani".|The Doctor (Seventh Doctor);Mel Bush
24||Time and the Rani: Part 2|Part 2 of "Time and the Rani".|The Doctor (Seventh Doctor);Mel Bush
24||Time and the Rani: Part 3|Part 3 of "Time and the Rani".|The Doctor (Seventh Doctor);Mel Bush
24||Time and the Rani: Part 4|Part 4 of "Time and the Rani".|The Doctor (Seventh Doctor);Mel Bush
24||Paradise Towers: Part 1|Part 1 of "Paradise Towers".|The Doctor (Seventh Doctor);Mel Bush
24||Paradise Towers: Part 2|Part 2 of "Paradise Towers".|The Doctor (Seventh Doctor);Mel Bush
24||Paradise Towers: Part 3|Part 3 of "Paradise Towers".|The Doctor (Seventh Doctor);Mel Bush
24||Paradise Towers: Part 4|Part 4 of "Paradise Towers".|The Doctor (Seventh Doctor);Mel Bush
24||Delta and the Bannermen: Part 1|Part 1 of "Delta and the Bannermen".|The Doctor (Seventh Doctor);Mel Bush
24||Delta and the Bannermen: Part 2|Part 2 of "Delta and the Bannermen".|The Doctor (Seventh Doctor);Mel Bush
24||Delta and the Bannermen: Part 3|Part 3 of "Delta and the Bannermen".|The Doctor (Seventh Doctor);Mel Bush
24||Dragonfire: Part 1|Part 1 of "Dragonfire".|The Doctor (Seventh Doctor);Mel Bush;Ace
24||Dragonfire: Part 2|Part 2 of "Dragonfire".|The Doctor (Seventh Doctor);Mel Bush;Ace
24||Dragonfire: Part 3|Part 3 of "Dragonfire".|The Doctor (Seventh Doctor);Mel Bush;Ace
25||Remembrance of the Daleks: Part 1|Part 1 of "Remembrance of the Daleks".|The Doctor (Seventh Doctor);Ace
25||Remembrance of the Daleks: Part 2|Part 2 of "Remembrance of the Daleks".|The Doctor (Seventh Doctor);Ace
25||Remembrance of the Daleks: Part 3|Part 3 of "Remembrance of the Daleks".|The Doctor (Seventh Doctor);Ace
25||Remembrance of the Daleks: Part 4|Part 4 of "Remembrance of the Daleks".|The Doctor (Seventh Doctor);Ace
25||The Happiness Patrol: Part 1|Part 1 of "The Happiness Patrol".|The Doctor (Seventh Doctor);Ace
25||The Happiness Patrol: Part 2|Part 2 of "The Happiness Patrol".|The Doctor (Seventh Doctor);Ace
25||The Happiness Patrol: Part 3|Part 3 of "The Happiness Patrol".|The Doctor (Seventh Doctor);Ace
25||Silver Nemesis: Part 1|Part 1 of "Silver Nemesis".|The Doctor (Seventh Doctor);Ace
25||Silver Nemesis: Part 2|Part 2 of "Silver Nemesis".|The Doctor (Seventh Doctor);Ace
25||Silver Nemesis: Part 3|Part 3 of "Silver Nemesis".|The Doctor (Seventh Doctor);Ace
25||The Greatest Show in the Galaxy: Part 1|Part 1 of "The Greatest Show in the Galaxy".|The Doctor (Seventh Doctor);Ace
25||The Greatest Show in the Galaxy: Part 2|Part 2 of "The Greatest Show in the Galaxy".|The Doctor (Seventh Doctor);Ace
25||The Greatest Show in the Galaxy: Part 3|Part 3 of "The Greatest Show in the Galaxy".|The Doctor (Seventh Doctor);Ace
25||The Greatest Show in the Galaxy: Part 4|Part 4 of "The Greatest Show in the Galaxy".|The Doctor (Seventh Doctor);Ace
26||Battlefield: Part 1|Part 1 of "Battlefield".|The Doctor (Seventh Doctor);Ace;Brigadier Lethbridge-Stewart
26||Battlefield: Part 2|Part 2 of "Battlefield".|The Doctor (Seventh Doctor);Ace;Brigadier Lethbridge-Stewart
26||Battlefield: Part 3|Part 3 of "Battlefield".|The Doctor (Seventh Doctor);Ace;Brigadier Lethbridge-Stewart
26||Battlefield: Part 4|Part 4 of "Battlefield".|The Doctor (Seventh Doctor);Ace;Brigadier Lethbridge-Stewart
26||Ghost Light: Part 1|Part 1 of "Ghost Light".|The Doctor (Seventh Doctor);Ace
26||Ghost Light: Part 2|Part 2 of "Ghost Light".|The Doctor (Seventh Doctor);Ace
26||Ghost Light: Part 3|Part 3 of "Ghost Light".|The Doctor (Seventh Doctor);Ace
26||The Curse of Fenric: Part 1|Part 1 of "The Curse of Fenric".|The Doctor (Seventh Doctor);Ace
26||The Curse of Fenric: Part 2|Part 2 of "The Curse of Fenric".|The Doctor (Seventh Doctor);Ace
26||The Curse of Fenric: Part 3|Part 3 of "The Curse of Fenric".|The Doctor (Seventh Doctor);Ace
26||The Curse of Fenric: Part 4|Part 4 of "The Curse of Fenric".|The Doctor (Seventh Doctor);Ace
26||Survival: Part 1|Part 1 of "Survival".|The Doctor (Seventh Doctor);Ace
26||Survival: Part 2|Part 2 of "Survival".|The Doctor (Seventh Doctor);Ace
26||Survival: Part 3|Part 3 of "Survival".|The Doctor (Seventh Doctor);Ace
EOF

echo "Ensuring known episodes..."
existing_eps=$(seed_api_get "$API/shows/$SHOW_ID/episodes")
declare -A season_episode_counter=()
while IFS='|' read -r season air_date title description chars; do
  [ -z "$season" ] && continue

  season_episode_counter["$season"]=$(( ${season_episode_counter["$season"]:-0} + 1 ))
  ep_index=${season_episode_counter["$season"]}
  episode_code=$(format_episode_code "$season" "$ep_index")
  placeholder_title="$episode_code"
  old_placeholder_title="S${season}E${ep_index}"
  placeholder_label="$placeholder_title"
  episode_payload=$(jq -nc \
    --argjson season "$season" \
    --arg date "$air_date" \
    --arg t "$title" \
    --arg d "$description" \
    '{season_number:$season, air_date:(($date | select(length>0)) // null), title:$t, description:$d}')

  existing_entry=$(printf '%s' "$existing_eps" | jq -c --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | (.[0] // empty)')
  ep_id=""
  if [ -n "$existing_entry" ]; then
    ep_id=$(printf '%s' "$existing_entry" | jq -r '.id')
    echo "  Episode exists (${episode_code}): $title"
  else
    placeholder_entry=$(printf '%s' "$existing_eps" | jq -c --arg t "$placeholder_title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | (.[0] // empty)')
    if [ -z "$placeholder_entry" ] && [ "$placeholder_title" != "$old_placeholder_title" ]; then
      placeholder_entry=$(printf '%s' "$existing_eps" | jq -c --arg t "$old_placeholder_title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | (.[0] // empty)')
      if [ -n "$placeholder_entry" ]; then
        placeholder_label="$old_placeholder_title"
      fi
    fi
    if [ -n "$placeholder_entry" ]; then
      ep_id=$(printf '%s' "$placeholder_entry" | jq -r '.id')
      echo "  Renaming placeholder ${placeholder_label} -> $title"
      response=$(seed_api_put "$API/episodes/$ep_id" -H 'Content-Type: application/json' -d "$episode_payload")
      if [ -n "$response" ]; then
        ep_id=$(printf '%s' "$response" | jq -r '.id // empty')
      fi
    else
      echo "  Creating episode (${episode_code}): $title"
      response=$(seed_api_post "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d "$episode_payload")
      ep_id=$(printf '%s' "$response" | jq -r '.id // empty')
    fi
    existing_eps=$(seed_api_get "$API/shows/$SHOW_ID/episodes")
  fi

  if [ -z "$ep_id" ] || [ "$ep_id" = "null" ]; then
    ep_id=$(seed_api_get "$API/shows/$SHOW_ID/episodes" | jq -r --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | (.[0].id // empty)')
    [ -z "$ep_id" ] && { echo "  Could not resolve episode id for season $season"; continue; }
  fi

  if [ -n "$chars" ]; then
    echo "$chars" | tr ';' '\n' | while IFS= read -r c; do
      [ -z "$c" ] && continue
      echo "    + $c"
      seed_api_post "$API/episodes/$ep_id/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$c" '{character_name:$n}')" >/dev/null
    done
  fi
done <<<"$EPISODES"

# --- create placeholder episodes to match IMDb counts ---
echo "Ensuring additional episodes..."
for season in $(seq 1 26); do
  total="$(lookup_epcount "$season" || true)"
  [ -z "$total" ] && continue
  y="$(lookup_year "$season" || true)"
  season_eps_json=$(seed_api_get "$API/shows/$SHOW_ID/seasons/$season/episodes")
  printf '%s\n' "$season_eps_json" | jq -r '.[] | "\(.id)|\(.title)"' | while IFS='|' read -r ep_id ep_title; do
    [ -z "$ep_id" ] && continue
    if [[ "$ep_title" =~ ^S([0-9]+)E([0-9]+)$ ]]; then
      season_digits=$((10#${BASH_REMATCH[1]}))
      episode_digits=$((10#${BASH_REMATCH[2]}))
      normalized_title=$(format_episode_code "$season_digits" "$episode_digits")
      if [ "$ep_title" != "$normalized_title" ]; then
        echo "  Normalizing placeholder title ${ep_title} -> ${normalized_title}"
        seed_api_put "$API/episodes/$ep_id" -H 'Content-Type: application/json' -d "$(jq -nc --arg t "$normalized_title" '{title:$t}')" >/dev/null
      fi
    fi
  done
  season_eps_json=$(seed_api_get "$API/shows/$SHOW_ID/seasons/$season/episodes")
  existing_count=$(printf '%s' "$season_eps_json" | jq 'length')
  if [ "$existing_count" -ge "$total" ]; then
    echo "Season $season already has $existing_count episodes"
    continue
  fi
  for ep in $(seq $((existing_count+1)) "$total"); do
    episode_code=$(format_episode_code "$season" "$ep")
    title="$episode_code"
    air_date=$(date -d "${y:-1900}-01-01 +$((ep-1)) weeks" +%Y-%m-%d 2>/dev/null || printf "%s-01-01" "${y:-1900}")
    description="Episode ${ep} of season ${season}."
    if seed_api_get "$API/shows/$SHOW_ID/episodes" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | length > 0' >/dev/null; then
      echo "  Episode exists (${episode_code}): $title"
    else
      echo "  Creating episode (${episode_code}): $title"
      jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season,air_date:$date, title:$t, description:$d}' | seed_api_post "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
    fi

    EP_ID=$(seed_api_get "$API/shows/$SHOW_ID/episodes" | jq -r --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | (.[0].id // empty)')
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
    seed_api_post "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$DOC" '{character_name:$n}')" >/dev/null

    case "$season" in
      1) COMP="Susan Foreman|Ian Chesterton|Barbara Wright" ;;
      2) COMP="Susan Foreman|Ian Chesterton|Barbara Wright" ;;
      3) COMP="Vicki|Steven Taylor" ;;
      4) COMP="Ben Jackson|Polly" ;;
      5) COMP="Jamie McCrimmon|Victoria Waterfield" ;;
      6) COMP="Jamie McCrimmon|Zoe Heriot" ;;
      7) COMP="Liz Shaw|Brigadier Lethbridge-Stewart" ;;
      8|9|10) COMP="Jo Grant|Brigadier Lethbridge-Stewart" ;;
      11) COMP="Sarah Jane Smith|Brigadier Lethbridge-Stewart" ;;
      12) COMP="Sarah Jane Smith|Harry Sullivan|Brigadier Lethbridge-Stewart" ;;
      13) COMP="Sarah Jane Smith|Harry Sullivan|Brigadier Lethbridge-Stewart" ;;
      14) COMP="Sarah Jane Smith" ;;
      15) COMP="Leela|K9" ;;
      16) COMP="Romana I|K9" ;;
      17|18) COMP="Romana II|K9" ;;
      19) COMP="Adric|Nyssa|Tegan Jovanka" ;;
      20) COMP="Nyssa|Tegan Jovanka" ;;
      21) COMP="Tegan Jovanka|Vislor Turlough" ;;
      22|23) COMP="Peri Brown" ;;
      24) COMP="Mel Bush" ;;
      25|26) COMP="Ace" ;;
      *) COMP="" ;;
    esac
    if [ -n "$COMP" ]; then
      echo "$COMP" | tr '|' '\n' | while IFS= read -r c; do
        [ -z "$c" ] && continue
        echo "    + $c"
        seed_api_post "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$c" '{character_name:$n}')" >/dev/null
      done
    fi
  done
done

echo "Seeding complete with episode-character links."
