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
  map(select(.title=="The Twilight Zone" and .year==1959)) | (.[0].id // empty)
')
if [ -z "${SHOW_ID:-}" ]; then
  SHOW_ID=$(seed_api_post "$API/shows" \
    -H 'Content-Type: application/json' \
    -d "$(json '{title:"The Twilight Zone", description:"Rod Serling anthology of speculative fiction", year:1959}')" \
    | jq -r '.id')
  echo "Created show: The Twilight Zone (id=$SHOW_ID)" >&2
else
  echo "Using existing show: The Twilight Zone (id=$SHOW_ID)" >&2
fi

read -r -d '' SEASONS <<'EOF_SEASONS' || true
1|1959
2|1960
3|1961
4|1963
5|1963
EOF_SEASONS

existing_seasons=$(seed_api_get "$API/shows/$SHOW_ID/seasons")
printf '%s\n' "$SEASONS" | while IFS='|' read -r s y; do
  [ -z "$s" ] && continue
  if echo "$existing_seasons" | jq -e --argjson s "$s" 'map(.season_number)|index($s)' >/dev/null; then
    echo "Season $s already exists"
  else
    echo "Creating Season $s (year $y)" >&2
    seed_api_post "$API/shows/$SHOW_ID/seasons" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --argjson s "$s" --argjson y "$y" '{season_number:$s, year:$y}')" >/dev/null
  fi
done

read -r -d '' EPISODES <<'EOF_EPISODES' || true
1|1959-10-02|Where Is Everybody?|An Air Force pilot wanders an eerily deserted town and questions his own sanity.|Mike Ferris=Earl Holliman;Narrator=Rod Serling
1|1959-10-09|One for the Angels|A kindly pitchman bargains with Death for time to deliver one last great sales pitch.|Lew Bookman=Ed Wynn;Death=Murray Hamilton;Narrator=Rod Serling
1|1959-10-16|Walking Distance|A stressed executive revisits his hometown only to find himself transported to his childhood past.|Martin Sloan=Gig Young;Narrator=Rod Serling
1|1959-11-20|Time Enough at Last|A bookish bank clerk survives a nuclear attack and finally has time to read—until fate intervenes.|Henry Bemis=Burgess Meredith;Helen Bemis=Jacqueline deWit;Narrator=Rod Serling
1|1960-03-04|The Monsters Are Due on Maple Street|Paranoia consumes a suburban block when the power fails and suspicion turns neighbor against neighbor.|Steve Brand=Claude Akins;Charlie Farnsworth=Jack Weston;Narrator=Rod Serling
1|1960-06-24|The Mighty Casey|A washed-up baseball team signs a robot pitcher whose gentle nature challenges what it means to win.|Mouth McGarry=Jack Warden;Dr. Stillman=Abraham Sofaer;Casey=Robert Sorrells;Narrator=Rod Serling
2|1960-09-30|King Nine Will Not Return|A bomber pilot is haunted by the desert crash of his squadron after awakening alone at the wreckage.|Captain James Embry=Robert Cummings;Narrator=Rod Serling
2|1960-11-11|Eye of the Beholder|A woman undergoes repeated surgeries to look “normal,” only to face a society with a very different definition of beauty.|Janet Tyler=Donna Douglas;Doctor Bernardi=William D. Gordon;Nurse=Jennifer Howard;Narrator=Rod Serling
2|1961-01-06|The Lateness of the Hour|An isolated family’s android servants become objects of resentment for their daughter.|Jana=Inger Stevens;Dr. Lars Loren=John Hoyt;Inger Loren=Irene Tedrow;Narrator=Rod Serling
2|1961-03-31|A Hundred Yards Over the Rim|A pioneer searching for medicine for his son stumbles into the future New Mexico desert.|Christian Horn=Cliff Robertson;Paula Horn=Miranda Jones;Narrator=Rod Serling
2|1961-05-19|Will the Real Martian Please Stand Up?|Stranded bus passengers suspect an alien among them during a snowbound night at a diner.|Ethel McConnell=Jean Willes;Ross=John Hoyt;Kanamit=N/A;Narrator=Rod Serling
2|1961-06-02|The Obsolete Man|A totalitarian state condemns a librarian, only to have him turn the tables during a televised execution.|Romney Wordsworth=Burgess Meredith;Chancellor=N/A;Narrator=Rod Serling
3|1961-10-13|It’s a Good Life|A small boy with godlike powers terrorizes his town by controlling every thought and emotion.|Anthony Fremont=Billy Mumy;Mr. Fremont=John Larch;Mrs. Fremont=Cloris Leachman;Narrator=Rod Serling
3|1961-10-20|The Grave|A gunslinger investigating his enemy’s death experiences supernatural justice.|Conny Miller=Lee Marvin;Ione Sykes=Elen Willard;Brother Johnny Rob=N/A;Narrator=Rod Serling
3|1961-10-27|The Mirror|A Caribbean dictator receives a mirror that reveals the faces of those who will kill him.|Ramos Clemente=Peter Falk;Cristo=Arnold Moss;Narrator=Rod Serling
3|1961-12-29|The Jungle|An engineer dismisses African curses, only to find the city itself turning against him.|Alan Talbot=John Dehner;Pauline Talbot=Emily McLaughlin;Narrator=Rod Serling
3|1962-03-02|To Serve Man|Earth rejoices when towering aliens share advanced technology—until their human cookbook is decoded.|Michael Chambers=Lloyd Bochner;Kanamit Ambassador=Richard Kiel;Patty Chambers=Susan Cummings;Narrator=Rod Serling
3|1962-06-01|Little Girl Lost|Parents seek their missing daughter, who vanished through a portal to another dimension behind her bed.|Chris Miller=Robert Sampson;Ruth Miller=Sarah Marshall;Bill=Charles Aidman;Narrator=Rod Serling
4|1963-01-03|In His Image|A man discovers he’s an android duplicate built to replace a flawed human original.|Alan Talbot=George Grizzard;Jessie Fremont=Gail Kobe;Narrator=Rod Serling
4|1963-01-17|Valley of the Shadow|A reporter stumbles into a hidden town guarded by advanced technology and harsh secrecy.|Phillip Redfield=Ed Nelson;Ellen Marshall=Natalie Trundy;Narrator=Rod Serling
4|1963-02-21|Mute|A telepathic girl raised by mind-speaking parents struggles to adapt to the spoken world.|Ilse Nielsen=Ann Jillian;Cora Wheeler=Barbara Baxley;Sheriff Wheeler=Frank Overton;Narrator=Rod Serling
4|1963-04-18|Printer’s Devil|An out-of-luck publisher signs a contract with a devilish typesetter who demands souls for scoops.|Douglas Winter=Robert Sterling;Mr. Smith=Burgess Meredith;Jackie Benson=Patricia Crowley;Narrator=Rod Serling
4|1963-05-02|On Thursday We Leave for Home|A weary colony leader resists evacuation as a rescue ship arrives to take his people back to Earth.|Captain William Benteen=James Whitmore;Colonel Sloane=Tim O'Connor;Narrator=Rod Serling
4|1963-06-06|The Bard|A struggling writer conjures William Shakespeare to pen scripts for television executives.|Julius Moomer=Jack Weston;William Shakespeare=John Williams;Rocky Rhodes=Burt Reynolds;Narrator=Rod Serling
5|1963-09-27|In Praise of Pip|A bookie prays for his wounded son and is granted a surreal chance at redemption in an amusement park.|Max Phillips=Jack Klugman;Pip Phillips=Billy Mumy;Narrator=Rod Serling
5|1963-10-11|Nightmare at 20,000 Feet|A nervous flyer insists he sees a creature on the wing of the plane while the crew doubts his sanity.|Bob Wilson=William Shatner;Julia Wilson=Christine White;Gremlin=Nick Cravat;Narrator=Rod Serling
5|1963-11-15|Living Doll|A child’s vindictive doll terrorizes her abusive stepfather with chilling threats.|Annabelle Streator=Mary La Roche;Erich Streator=Telly Savalas;Talky Tina=June Foray;Narrator=Rod Serling
5|1964-01-03|Night Call|An elderly woman receives mysterious phone calls that blur the line between life and death.|Elva Keene=Gladys Cooper;Brian Douglas=John Emery;Narrator=Rod Serling
5|1964-02-28|The Masks|A dying patriarch forces his greedy heirs to wear grotesque masks until midnight—with lasting consequences.|Jason Foster=Robert Keith;Paula Harper=Virginia Gregg;Narrator=Rod Serling
5|1964-03-20|I Am the Night—Color Me Black|A town consumed by hatred finds dawn delayed as darkness spreads worldwide.|Sheriff Charlie Koch=Michael Constantine;Jody Brown=Ivan Dixon;Narrator=Rod Serling
EOF_EPISODES

ensure_episode() {
  local season="$1" air_date="$2" title="$3" description="$4"
  local existing
  existing=$(seed_api_get "$API/shows/$SHOW_ID/episodes" | jq -c --arg t "$title" --argjson s "$season" 'map(select(.season_number==$s and .title==$t)) | (.[0] // empty)')
  if [ -n "$existing" ]; then
    local current_desc
    current_desc=$(printf '%s' "$existing" | jq -r '.description // ""')
    if [ "$current_desc" != "$description" ]; then
      echo "Updating episode description: $title" >&2
      seed_api_put "$API/episodes/$(printf '%s' "$existing" | jq -r '.id')" \
        -H 'Content-Type: application/json' \
        -d "$(jq -nc --argjson season "$season" --arg date "$air_date" --arg d "$description" '{season_number:$season, air_date:$date, description:$d}')" >/dev/null
    else
      echo "Episode exists (S${season}): $title" >&2
    fi
    printf '%s' "$existing" | jq -r '.id'
  else
    echo "Creating episode (S${season}): $title" >&2
    seed_api_post "$API/shows/$SHOW_ID/episodes" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season, air_date:$date, title:$t, description:$d}')" \
      | jq -r '.id'
  fi
}

printf '%s\n' "$EPISODES" | while IFS='|' read -r season air_date title description char_blob; do
  [ -z "$season" ] && continue
  EP_ID=$(ensure_episode "$season" "$air_date" "$title" "$description")
  [ -z "$EP_ID" ] && { echo "Could not resolve episode id for $title"; continue; }
  IFS=';' read -ra CHARS <<<"$char_blob"
  for entry in "${CHARS[@]}"; do
    [ -z "$entry" ] && continue
    char_name="${entry%%=*}"
    actor_name=""
    if [[ "$entry" == *"="* ]]; then
      actor_name="${entry#*=}"
    fi
    payload=$(jq -nc --arg n "$char_name" --arg a "$actor_name" '
      if ($a | length) > 0 then {character_name:$n, actor_name:$a}
      else {character_name:$n}
      end
    ')
    echo "  Linking $char_name (actor: ${actor_name:-unknown})"
    seed_api_post "$API/episodes/$EP_ID/characters" \
      -H 'Content-Type: application/json' \
      -d "$payload" >/dev/null
  done
done

echo "Twilight Zone seeding complete."
