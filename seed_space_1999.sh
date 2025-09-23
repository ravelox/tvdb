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
  map(select(.title=="Space: 1999" and .year==1975)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(seed_api_post "$API/shows" -H 'Content-Type: application/json' -d "$(json '{title:"Space: 1999", description:"British-Italian science fiction series", year:1975}')" | jq -r '.id')
  echo "Created show: Space: 1999 (id=$SHOW_ID)"
else
  echo "Using existing show: Space: 1999 (id=$SHOW_ID)"
fi

read -r -d '' SEASONS <<'EOF_SEASONS' || true
1|1975
2|1976
EOF_SEASONS

existing_seasons=$(seed_api_get "$API/shows/$SHOW_ID/seasons")
printf '%s\n' "$SEASONS" | while IFS='|' read -r s y; do
  [ -z "$s" ] && continue
  if echo "$existing_seasons" | jq -e --argjson s "$s" 'map(.season_number)|index($s)' >/dev/null; then
    echo "Season $s already exists"
  else
    echo "Creating Season $s (year $y)"
    seed_api_post "$API/shows/$SHOW_ID/seasons" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --argjson s "$s" --argjson y "$y" '{season_number:$s, year:$y}')" >/dev/null
  fi
done

read -r -d '' ACTORS <<'EOF_ACTORS' || true
Martin Landau
Barbara Bain
Barry Morse
Nick Tate
Prentis Hancock
Zienia Merton
Clifton Jones
Anton Phillips
Suzanne Roquette
Catherine Schell
Tony Anholt
Jeffrey Kissoon
Yasuko Nagazumi
EOF_ACTORS

actors_json=$(seed_api_get "$API/actors")
printf '%s\n' "$ACTORS" | while IFS= read -r name; do
  [ -z "$name" ] && continue
  if echo "$actors_json" | jq -e --arg n "$name" 'map(.name)|index($n)' >/dev/null; then
    echo "Actor exists: $name"
  else
    echo "Creating actor: $name"
    seed_api_post "$API/actors" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg n "$name" '{name:$n}')" >/dev/null
  fi
done
actors_json=$(seed_api_get "$API/actors")

read -r -d '' CHAR_TO_ACTOR <<'EOF_CHARS' || true
Commander John Koenig|Martin Landau
Dr. Helena Russell|Barbara Bain
Professor Victor Bergman|Barry Morse
Captain Alan Carter|Nick Tate
Paul Morrow|Prentis Hancock
Sandra Benes|Zienia Merton
David Kano|Clifton Jones
Dr. Bob Mathias|Anton Phillips
Tanya Alexander|Suzanne Roquette
Maya|Catherine Schell
Tony Verdeschi|Tony Anholt
Dr. Ben Vincent|Jeffrey Kissoon
Yasko|Yasuko Nagazumi
EOF_CHARS

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
      seed_api_put "$API/characters/$char_id" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg a "$actor" '{actor_name:$a}')" >/dev/null
    else
      echo "Character exists: $char (actor: ${current_actor:-none})"
    fi
  else
    echo "Creating character: $char (actor: $actor)"
    seed_api_post "$API/shows/$SHOW_ID/characters" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg n "$char" --arg a "$actor" '{name:$n, actor_name:$a}')" >/dev/null
  fi
done

S1_CHARS="Commander John Koenig=Martin Landau;Dr. Helena Russell=Barbara Bain;Professor Victor Bergman=Barry Morse;Captain Alan Carter=Nick Tate;Paul Morrow=Prentis Hancock;Sandra Benes=Zienia Merton"
S1_PLUS_KANO="Commander John Koenig=Martin Landau;Dr. Helena Russell=Barbara Bain;Professor Victor Bergman=Barry Morse;Captain Alan Carter=Nick Tate;Sandra Benes=Zienia Merton;David Kano=Clifton Jones"
S1_PLUS_MATHIAS="Commander John Koenig=Martin Landau;Dr. Helena Russell=Barbara Bain;Professor Victor Bergman=Barry Morse;Captain Alan Carter=Nick Tate;Paul Morrow=Prentis Hancock;Dr. Bob Mathias=Anton Phillips"
S2_CHARS="Commander John Koenig=Martin Landau;Dr. Helena Russell=Barbara Bain;Maya=Catherine Schell;Tony Verdeschi=Tony Anholt;Captain Alan Carter=Nick Tate;Sandra Benes=Zienia Merton;Dr. Ben Vincent=Jeffrey Kissoon"
S2_WITH_YASKO="Commander John Koenig=Martin Landau;Dr. Helena Russell=Barbara Bain;Maya=Catherine Schell;Tony Verdeschi=Tony Anholt;Captain Alan Carter=Nick Tate;Yasko=Yasuko Nagazumi;Dr. Ben Vincent=Jeffrey Kissoon"

read -r -d '' EPISODES <<'EOF_EPISODES' || true
1|1975-09-04|Breakaway|A nuclear waste explosion hurls Moonbase Alpha into deep space.|S1
1|1975-09-11|Matter of Life and Death|A survivor from a doomed mission brings an antimatter threat back to Alpha.|S1
1|1975-09-18|Black Sun|The Moon is drawn toward a mysterious black sun that defies physics.|S1_PLUS_KANO
1|1975-09-25|Ring Around the Moon|An alien probe traps the Moon to catalogue humanity.|S1
1|1975-10-02|Earthbound|Exiled aliens offer a way back to Earth for a terrible price.|S1
1|1975-10-09|Another Time, Another Place|A duplicate Moon reveals Alpha's possible future.|S1
1|1975-10-16|Missing Link|Koenig is studied by an alien scientist while lying comatose.|S1_PLUS_MATHIAS
1|1975-10-23|Guardian of Piri|A seductive computer lures Alphans into blissful catatonia.|S1
1|1975-10-30|Force of Life|An energy being possesses technician Anton Zoref and drains power.|S1_PLUS_KANO
1|1975-11-06|Alpha Child|A newborn rapidly matures into a telekinetic agent of an alien race.|S1
1|1975-11-13|The Last Sunset|A mysterious probe gives Alpha an atmosphere that soon turns deadly.|S1
1|1975-11-20|Voyager's Return|The creator of a deadly probe seeks redemption among the Alphans.|S1_PLUS_KANO
1|1975-11-27|Collision Course|Koenig must trust a visionary who claims collision means salvation.|S1
1|1975-12-04|Death's Other Dominion|Immortality tempts the Alphans on the frozen world Ultima Thule.|S1
1|1975-12-11|The Full Circle|A time mist devolves Alphans into prehistoric hunters.|S1_PLUS_KANO
1|1975-12-18|End of Eternity|A murderous immortal is freed from an asteroid prison.|S1
1|1975-12-25|War Games|Illusions of war test Koenig's resolve and empathy.|S1_PLUS_KANO
1|1976-01-01|The Last Enemy|Alpha is caught between two warring planets bent on annihilation.|S1
1|1976-01-08|The Troubled Spirit|A musician's experiments unleash a vengeful apparition.|S1_PLUS_MATHIAS
1|1976-01-15|Space Brain|A colossal brain defends itself from an accidental attack.|S1_PLUS_KANO
1|1976-01-22|The Infernal Machine|A lonely living starship named Gwent seeks companionship.|S1
1|1976-01-29|Mission of the Darians|Refugees on a vast generation ship prey on devolved survivors.|S1
1|1976-02-05|Dragon's Domain|An astronaut confronts the nightmare that destroyed his crew.|S1_PLUS_KANO
1|1976-02-12|Testament of Arkadia|Ruins hint that the Alphans' ancestors seeded life on Earth.|S1
2|1976-09-04|The Metamorph|Mentor of Psychon imprisons Alphans while Maya questions her loyalty.|S2_CHARS
2|1976-09-11|The Exiles|Cryonic exiles awaken and demand revenge on their homeworld.|S2_CHARS
2|1976-09-18|One Moment of Humanity|Emotionless androids abduct Maya to learn passion.|S2_WITH_YASKO
2|1976-09-25|All That Glisters|A living rock drains Alpha's water to survive.|S2_CHARS
2|1976-10-02|Journey to Where|A teleport experiment strands an Alpha team in 14th-century Scotland.|S2_CHARS
2|1976-10-09|The Taybor|A flamboyant trader offers passage home for a shocking price.|S2_CHARS
2|1976-10-16|The Rules of Luton|A sentient planet puts Koenig and Maya on trial by combat.|S2_CHARS
2|1976-10-23|The Mark of Archanon|A fugitive family carries a dangerous psychic legacy.|S2_CHARS
2|1976-10-30|Brian the Brain|A whimsical robot commandeers the Eagle fleet for its own mission.|S2_CHARS
2|1976-11-06|New Adam, New Eve|A godlike being reshuffles Alpha's command team to found a new Eden.|S2_WITH_YASKO
2|1976-11-13|The AB Chrysalis|A planet's automated defenses prepare to obliterate Alpha.|S2_CHARS
2|1976-11-20|Catacombs of the Moon|A desperate search for titanium reveals hidden caverns beneath Alpha.|S2_CHARS
2|1976-11-27|Seed of Destruction|A ruthless duplicate of Koenig seeks to drain Alpha's energy.|S2_CHARS
2|1976-12-04|The Beta Cloud|A hulking guardian storms Alpha to steal its life support.|S2_CHARS
2|1976-12-11|A Matter of Balance|A dimension-hopping predator targets Maya to sustain itself.|S2_WITH_YASKO
2|1976-12-18|Space Warp|Maya's fever triggers uncontrollable shapeshifting as Koenig is captured.|S2_CHARS
2|1976-12-25|The Bringers of Wonder Part 1|Alpha celebrates unexpected visitors who may be monstrous deceivers.|S2_CHARS
2|1977-01-01|The Bringers of Wonder Part 2|Koenig fights to expose the aliens before Alpha is consumed.|S2_CHARS
2|1977-01-08|The Seance Spectre|A fanatic mutineer promises salvation through deadly visions.|S2_WITH_YASKO
2|1977-01-15|Dorzak|Maya's revered mentor manipulates Alpha after his rescue from stasis.|S2_CHARS
2|1977-01-22|The Lambda Factor|A mysterious energy field amplifies hidden guilt and telepathy.|S2_WITH_YASKO
2|1977-01-29|The Immunity Syndrome|An alien organism renders Alpha's environment lethal to humans.|S2_CHARS
2|1977-02-05|Devil's Planet|Koenig is trapped on a prison world ruled by ruthless wardens.|S2_CHARS
2|1977-02-12|The Dorcons|A dying empire hunts Maya for the secret of immortality.|S2_CHARS
EOF_EPISODES

existing_eps=$(seed_api_get "$API/shows/$SHOW_ID/episodes")
printf '%s\n' "$EPISODES" | while IFS='|' read -r season air_date title description char_key; do
  [ -z "$season" ] && continue
  if echo "$existing_eps" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t))|length>0' >/dev/null; then
    echo "Episode exists (S${season}): $title"
  else
    echo "Creating episode (S${season}): $title"
    jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season, air_date:$date, title:$t, description:$d}' |
      seed_api_post "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
  fi
  EP_ID=$(seed_api_get "$API/shows/$SHOW_ID/episodes" | jq -r --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t)) | (.[0].id // empty)')
  [ -z "$EP_ID" ] && { echo "Could not resolve episode id for season $season"; continue; }

  case "$char_key" in
    S1) char_list="$S1_CHARS" ;;
    S1_PLUS_KANO) char_list="$S1_PLUS_KANO" ;;
    S1_PLUS_MATHIAS) char_list="$S1_PLUS_MATHIAS" ;;
    S2_CHARS) char_list="$S2_CHARS" ;;
    S2_WITH_YASKO) char_list="$S2_WITH_YASKO" ;;
    *) char_list="$char_key" ;;
  esac

  echo "$char_list" | tr ';' '\n' | while IFS='=' read -r char_name actor_name; do
    [ -z "$char_name" ] && continue
    echo "  Linking $char_name (actor: $actor_name)"
    seed_api_post "$API/episodes/$EP_ID/characters" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg n "$char_name" --arg a "$actor_name" '{character_name:$n, actor_name:$a}')" >/dev/null || true
  done

done

echo "Space: 1999 seeding complete"
