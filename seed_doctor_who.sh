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
  if echo "$chars_json" | jq -e --arg n "$char" 'map(.name) | index($n)' >/dev/null; then
    echo "  Character exists: $char"
  else
    echo "  Creating character: $char (actor: $actor)"
    seed_api_post "$API/shows/$SHOW_ID/characters" -H 'Content-Type: application/json'       -d "$(jq -nc --arg n "$char" --arg a "$actor" '{name:$n, actor_name:$a}')" >/dev/null
  fi
done

# --- episodes: first five per season ---
read -r -d '' EPISODES <<'EOF' || true
1|1963-11-23|An Unearthly Child|Series premiere.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1|1963-11-30|The Cave of Skulls|The TARDIS crew faces Stone Age dangers.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1|1963-12-07|The Forest of Fear|The travellers strive to escape the tribe.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1|1963-12-14|The Firemaker|Ian's plan to help the tribe backfires.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
1|1963-12-21|The Dead Planet|The crew explores a seemingly lifeless world.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2|1964-10-31|Planet of Giants|The crew is accidentally miniaturized.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2|1964-11-07|Dangerous Journey|The tiny travelers face a deadly insecticide.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2|1964-11-14|Crisis|The team sabotages the pesticide to save humanity.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2|1964-11-21|World's End|The Daleks occupy a future Earth.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
2|1964-11-28|The Daleks|The travellers confront Daleks in ruined London.|The Doctor (First Doctor);Susan Foreman;Ian Chesterton;Barbara Wright
3|1965-09-11|Four Hundred Dawns|The Doctor meets the stranded Drahvins and Rills on a doomed world.|The Doctor (First Doctor);Vicki;Steven Taylor
3|1965-09-18|Trap of Steel|The Drahvins imprison the Doctor's friends.|The Doctor (First Doctor);Vicki;Steven Taylor
3|1965-09-25|Air Lock|Steven's escape attempt leads to Rill contact.|The Doctor (First Doctor);Vicki;Steven Taylor
3|1965-10-02|The Exploding Planet|The travelers race to leave the doomed world.|The Doctor (First Doctor);Vicki;Steven Taylor
3|1965-10-09|Temple of Secrets|Arriving in ancient Troy, the Doctor is mistaken for a prophet.|The Doctor (First Doctor);Vicki;Steven Taylor
4|1966-09-10|The Smugglers: Part 1|The TARDIS lands in 17th-century Cornwall amid pirate schemes.|The Doctor (First Doctor);Ben Jackson;Polly
4|1966-09-17|The Smugglers: Part 2|Captain Pike plots to seize hidden treasure.|The Doctor (First Doctor);Ben Jackson;Polly
4|1966-09-24|The Smugglers: Part 3|The Doctor seeks the cryptic clues to Avery's gold.|The Doctor (First Doctor);Ben Jackson;Polly
4|1966-10-01|The Smugglers: Part 4|A storm and betrayal doom the smugglers' plan.|The Doctor (First Doctor);Ben Jackson;Polly
4|1966-10-08|The Tenth Planet: Part 1|Earth faces invasion from the mysterious Mondas.|The Doctor (First Doctor);Ben Jackson;Polly
5|1967-09-02|The Tomb of the Cybermen: Part 1|Archaeologists awaken dormant Cybermen on Telos.|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5|1967-09-09|The Tomb of the Cybermen: Part 2|The expedition explores the chilling tomb.|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5|1967-09-16|The Tomb of the Cybermen: Part 3|The revived Cybermen reveal their sinister plans.|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5|1967-09-23|The Tomb of the Cybermen: Part 4|The Doctor traps the Cybermen back in hibernation.|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
5|1967-09-30|The Abominable Snowmen: Part 1|Monks in the Himalayas fear a Yeti menace.|The Doctor (Second Doctor);Jamie McCrimmon;Victoria Waterfield
6|1968-08-10|The Dominators: Part 1|The Dominators and their Quarks threaten the pacifist planet Dulkis.|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6|1968-08-17|The Dominators: Part 2|The Doctor is forced to aid the invaders' drilling.|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6|1968-08-24|The Dominators: Part 3|Jamie leads resistance against the Quarks.|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6|1968-08-31|The Dominators: Part 4|Zoe devises a way to disable the Quarks.|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
6|1968-09-07|The Dominators: Part 5|A volcanic eruption destroys the Dominators' plan.|The Doctor (Second Doctor);Jamie McCrimmon;Zoe Heriot
7|1970-01-03|Spearhead from Space: Part 1|Autons invade Earth as the Doctor recovers from regeneration.|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7|1970-01-10|Spearhead from Space: Part 2|Nestene energy animates plastic killers.|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7|1970-01-17|Spearhead from Space: Part 3|The Doctor battles the Autons in a factory.|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7|1970-01-24|Spearhead from Space: Part 4|The Nestene attempts to conquer through the Doctor's mind.|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
7|1970-01-31|Doctor Who and the Silurians: Part 1|Unearthed reptiles challenge humanity's dominance.|The Doctor (Third Doctor);Liz Shaw;Brigadier Lethbridge-Stewart
8|1971-01-02|Terror of the Autons: Part 1|The Master allies with the Nestene to unleash killer plastics.|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8|1971-01-09|Terror of the Autons: Part 2|Deadly dolls and wires sow panic.|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8|1971-01-16|Terror of the Autons: Part 3|The Master prepares to summon the Nestene power.|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8|1971-01-23|Terror of the Autons: Part 4|The Doctor thwarts the Master's invasion scheme.|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
8|1971-01-30|The Mind of Evil: Part 1|A prison experiment unleashes a mind parasite.|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9|1972-01-01|Day of the Daleks: Part 1|Time-traveling rebels try to avert a Dalek-controlled future.|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9|1972-01-08|Day of the Daleks: Part 2|The Doctor becomes a pawn in the temporal war.|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9|1972-01-15|Day of the Daleks: Part 3|UNIT prepares for a Dalek assault.|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9|1972-01-22|Day of the Daleks: Part 4|The Doctor stops the paradox and foils the Daleks.|The Doctor (Third Doctor);Jo Grant;Brigadier Lethbridge-Stewart
9|1972-01-29|The Curse of Peladon: Part 1|A royal mystery threatens Peladon's entry into the Federation.|The Doctor (Third Doctor);Jo Grant
10|1972-12-30|The Three Doctors: Part 1|Three incarnations unite to battle Omega.|The Doctor (Third Doctor);The Doctor (Second Doctor);The Doctor (First Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10|1973-01-06|The Three Doctors: Part 2|The Doctors venture into the antimatter universe.|The Doctor (Third Doctor);The Doctor (Second Doctor);The Doctor (First Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10|1973-01-13|The Three Doctors: Part 3|Omega traps the Doctors within his realm.|The Doctor (Third Doctor);The Doctor (Second Doctor);The Doctor (First Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10|1973-01-20|The Three Doctors: Part 4|Omega is defeated and the Doctor's exile ends.|The Doctor (Third Doctor);The Doctor (Second Doctor);The Doctor (First Doctor);Jo Grant;Brigadier Lethbridge-Stewart
10|1973-01-27|Carnival of Monsters: Part 1|A miniscope traps the Doctor and Jo in a showman's device.|The Doctor (Third Doctor);Jo Grant
11|1973-12-15|The Time Warrior: Part 1|A Sontaran warrior abducts scientists to the Middle Ages.|The Doctor (Third Doctor);Sarah Jane Smith
11|1973-12-22|The Time Warrior: Part 2|Sarah investigates the mysterious castle.|The Doctor (Third Doctor);Sarah Jane Smith
11|1973-12-29|The Time Warrior: Part 3|The Doctor confronts Linx's plans.|The Doctor (Third Doctor);Sarah Jane Smith
11|1974-01-05|The Time Warrior: Part 4|The Doctor forces Linx to abandon his scheme.|The Doctor (Third Doctor);Sarah Jane Smith
11|1974-01-12|Invasion of the Dinosaurs: Part 1|London is evacuated as dinosaurs appear in the streets.|The Doctor (Third Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart
12|1974-12-28|Robot: Part 1|A giant robot is manipulated to steal secrets for a fanatical group.|The Doctor (Fourth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Harry Sullivan
12|1975-01-04|Robot: Part 2|The Doctor suspects K1's programming has been altered.|The Doctor (Fourth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Harry Sullivan
12|1975-01-11|Robot: Part 3|UNIT battles the robot as it grows more powerful.|The Doctor (Fourth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Harry Sullivan
12|1975-01-18|Robot: Part 4|The Doctor stops the nuclear launch and saves the robot.|The Doctor (Fourth Doctor);Sarah Jane Smith;Brigadier Lethbridge-Stewart;Harry Sullivan
12|1975-01-25|The Ark in Space: Part 1|The TARDIS arrives on an abandoned space station poised to revive humanity.|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan
13|1975-08-30|Terror of the Zygons: Part 1|Shape-shifting Zygons plot to conquer Earth from Loch Ness.|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan;Brigadier Lethbridge-Stewart
13|1975-09-06|Terror of the Zygons: Part 2|The Zygons unleash the Skarasen on Scotland.|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan;Brigadier Lethbridge-Stewart
13|1975-09-13|Terror of the Zygons: Part 3|The Doctor infiltrates the Zygon ship.|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan;Brigadier Lethbridge-Stewart
13|1975-09-20|Terror of the Zygons: Part 4|The Doctor foils the invasion and departs with Sarah and Harry.|The Doctor (Fourth Doctor);Sarah Jane Smith;Harry Sullivan;Brigadier Lethbridge-Stewart
13|1975-09-27|Planet of Evil: Part 1|A jungle world harbors a deadly antimatter creature.|The Doctor (Fourth Doctor);Sarah Jane Smith
14|1976-09-04|The Masque of Mandragora: Part 1|A mysterious energy draws the TARDIS to Renaissance Italy.|The Doctor (Fourth Doctor);Sarah Jane Smith
14|1976-09-11|The Masque of Mandragora: Part 2|The Mandragora Helix manipulates a secret cult.|The Doctor (Fourth Doctor);Sarah Jane Smith
14|1976-09-18|The Masque of Mandragora: Part 3|Sarah is prepared for sacrifice by the cult.|The Doctor (Fourth Doctor);Sarah Jane Smith
14|1976-09-25|The Masque of Mandragora: Part 4|The Doctor expels the Helix and saves the duke.|The Doctor (Fourth Doctor);Sarah Jane Smith
14|1976-10-02|The Hand of Fear: Part 1|A quarry blast frees an ancient alien hand.|The Doctor (Fourth Doctor);Sarah Jane Smith
15|1977-09-03|Horror of Fang Rock: Part 1|An alien hunts the Doctor and lighthouse crew in thick fog.|The Doctor (Fourth Doctor);Leela
15|1977-09-10|Horror of Fang Rock: Part 2|A survivor hides a deadly secret.|The Doctor (Fourth Doctor);Leela
15|1977-09-17|Horror of Fang Rock: Part 3|The Rutan reveals its plan to signal reinforcements.|The Doctor (Fourth Doctor);Leela
15|1977-09-24|Horror of Fang Rock: Part 4|The Doctor destroys the Rutan with a makeshift bomb.|The Doctor (Fourth Doctor);Leela
15|1977-10-01|The Invisible Enemy: Part 1|A space virus infects the Doctor's mind.|The Doctor (Fourth Doctor);Leela;K9
16|1978-09-02|The Ribos Operation: Part 1|The Doctor begins the Key to Time quest on the cold world Ribos.|The Doctor (Fourth Doctor);Romana I;K9
16|1978-09-09|The Ribos Operation: Part 2|Con-men plot to sell a planet to the Graff Vynda-K.|The Doctor (Fourth Doctor);Romana I;K9
16|1978-09-16|The Ribos Operation: Part 3|The Doctor seeks the first segment amid catacombs.|The Doctor (Fourth Doctor);Romana I;K9
16|1978-09-23|The Ribos Operation: Part 4|The Doctor outwits the Graff and secures the segment.|The Doctor (Fourth Doctor);Romana I;K9
16|1978-09-30|The Pirate Planet: Part 1|A hollow world plunders planets for its riches.|The Doctor (Fourth Doctor);Romana I;K9
17|1979-09-01|Destiny of the Daleks: Part 1|The Doctor is caught in a stalemate between Daleks and Movellans.|The Doctor (Fourth Doctor);Romana II;K9
17|1979-09-08|Destiny of the Daleks: Part 2|The Daleks capture the Doctor to locate Davros.|The Doctor (Fourth Doctor);Romana II;K9
17|1979-09-15|Destiny of the Daleks: Part 3|Davros plots to lead the Daleks once more.|The Doctor (Fourth Doctor);Romana II;K9
17|1979-09-22|Destiny of the Daleks: Part 4|The Movellans plan to destroy Skaro.|The Doctor (Fourth Doctor);Romana II;K9
17|1979-09-29|City of Death: Part 1|Time slips in Paris hint at a fragmented villain.|The Doctor (Fourth Doctor);Romana II;K9
18|1980-08-30|The Leisure Hive: Part 1|A tourist world harbors deadly experiments and political intrigue.|The Doctor (Fourth Doctor);Romana II;K9
18|1980-09-06|The Leisure Hive: Part 2|The Doctor is aged by the Tachyon Recreation Generator.|The Doctor (Fourth Doctor);Romana II;K9
18|1980-09-13|The Leisure Hive: Part 3|The Foamasi expose a criminal scheme.|The Doctor (Fourth Doctor);Romana II;K9
18|1980-09-20|The Leisure Hive: Part 4|The Doctor reverses Pangol's clone army.|The Doctor (Fourth Doctor);Romana II;K9
18|1980-09-27|Meglos: Part 1|A shape-shifting cactus impersonates the Doctor.|The Doctor (Fourth Doctor);Romana II;K9
19|1982-01-04|Castrovalva: Part 1|The Master traps the disoriented Doctor in a recursive city.|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19|1982-01-11|Castrovalva: Part 2|The city begins to unravel as the Master closes in.|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19|1982-01-18|Castrovalva: Part 3|Adric's manipulation threatens the Doctor's escape.|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19|1982-01-25|Castrovalva: Part 4|The Doctor exposes the illusion and defeats the Master.|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
19|1982-02-01|Four to Doomsday: Part 1|Monarch's starship hides a plan to conquer Earth.|The Doctor (Fifth Doctor);Adric;Nyssa;Tegan Jovanka
20|1983-01-03|Arc of Infinity: Part 1|A creature from antimatter seeks form on Gallifrey through the Doctor.|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20|1983-01-10|Arc of Infinity: Part 2|The Time Lords plan to execute the Doctor.|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20|1983-01-17|Arc of Infinity: Part 3|Omega's return threatens Amsterdam and Gallifrey.|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20|1983-01-24|Arc of Infinity: Part 4|Nyssa helps free the Doctor from Omega's control.|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
20|1983-01-31|Snakedance: Part 1|The Mara resurfaces through Tegan's nightmares.|The Doctor (Fifth Doctor);Nyssa;Tegan Jovanka
21|1984-01-05|Warriors of the Deep: Part 1|Silurians and Sea Devils attack an underwater base in 2084.|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21|1984-01-12|Warriors of the Deep: Part 2|The Doctor attempts peace talks with the reptiles.|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21|1984-01-19|Warriors of the Deep: Part 3|The Myrka breaks into the base.|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21|1984-01-26|Warriors of the Deep: Part 4|The Doctor triggers a gas to stop the reptile assault.|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
21|1984-02-02|The Awakening: Part 1|A war game in a village awakens an ancient entity.|The Doctor (Fifth Doctor);Tegan Jovanka;Vislor Turlough
22|1985-01-05|Attack of the Cybermen: Part 1|The Doctor prevents Cybermen from altering Earth's history.|The Doctor (Sixth Doctor);Peri Brown
22|1985-01-12|Attack of the Cybermen: Part 2|Cyber control on Telos is destroyed.|The Doctor (Sixth Doctor);Peri Brown
22|1985-01-19|Vengeance on Varos: Part 1|The Doctor lands on a world ruled by televised torture.|The Doctor (Sixth Doctor);Peri Brown
22|1985-01-26|Vengeance on Varos: Part 2|A revolution overturns Varos's sadistic regime.|The Doctor (Sixth Doctor);Peri Brown
22|1985-02-02|The Mark of the Rani: Part 1|The Doctor meets another renegade Time Lord.|The Doctor (Sixth Doctor);Peri Brown
23|1986-09-06|The Mysterious Planet: Part 1|The Doctor is tried while uncovering secrets of Ravolox.|The Doctor (Sixth Doctor);Peri Brown
23|1986-09-13|The Mysterious Planet: Part 2|The Valeyard presents evidence of the Doctor's meddling.|The Doctor (Sixth Doctor);Peri Brown
23|1986-09-20|The Mysterious Planet: Part 3|Glitz and Dibber seek the hidden L3 robot.|The Doctor (Sixth Doctor);Peri Brown
23|1986-09-27|The Mysterious Planet: Part 4|The Doctor exposes the fate of Earth and the Matrix scheme.|The Doctor (Sixth Doctor);Peri Brown
23|1986-10-04|Mindwarp: Part 1|On Thoros Beta, the Doctor investigates weapon deals.|The Doctor (Sixth Doctor);Peri Brown
24|1987-09-07|Time and the Rani: Part 1|A newly regenerated Doctor confronts the Rani's experiments.|The Doctor (Seventh Doctor);Mel Bush
24|1987-09-14|Time and the Rani: Part 2|The Rani uses a brain drain to power her plan.|The Doctor (Seventh Doctor);Mel Bush
24|1987-09-21|Time and the Rani: Part 3|The Doctor faces mutant bat creatures.|The Doctor (Seventh Doctor);Mel Bush
24|1987-09-28|Time and the Rani: Part 4|The Doctor frees the kidnapped geniuses.|The Doctor (Seventh Doctor);Mel Bush
24|1987-10-05|Paradise Towers: Part 1|Kangs battle caretakers in a dystopian high-rise.|The Doctor (Seventh Doctor);Mel Bush
25|1988-10-05|Remembrance of the Daleks: Part 1|Dalek factions battle over the Hand of Omega in 1963 London.|The Doctor (Seventh Doctor);Ace
25|1988-10-12|Remembrance of the Daleks: Part 2|The Doctor manipulates the warring Dalek groups.|The Doctor (Seventh Doctor);Ace
25|1988-10-19|Remembrance of the Daleks: Part 3|The Renegade Daleks seize control of a school.|The Doctor (Seventh Doctor);Ace
25|1988-10-26|Remembrance of the Daleks: Part 4|The Doctor destroys Skaro with the Hand of Omega.|The Doctor (Seventh Doctor);Ace
25|1988-11-02|The Happiness Patrol: Part 1|A regime enforcing cheerfulness hides dark secrets.|The Doctor (Seventh Doctor);Ace
26|1989-09-06|Battlefield: Part 1|The Doctor faces Arthurian foes when Morgaine invades modern Britain.|The Doctor (Seventh Doctor);Ace;Brigadier Lethbridge-Stewart
26|1989-09-13|Battlefield: Part 2|The Brigadier returns to help combat the knights.|The Doctor (Seventh Doctor);Ace;Brigadier Lethbridge-Stewart
26|1989-09-20|Battlefield: Part 3|Morgaine seeks Excalibur beneath a lake.|The Doctor (Seventh Doctor);Ace;Brigadier Lethbridge-Stewart
26|1989-09-27|Battlefield: Part 4|Morgaine is defeated and peace restored.|The Doctor (Seventh Doctor);Ace;Brigadier Lethbridge-Stewart
26|1989-10-04|Ghost Light: Part 1|An evolving house harbors Earth's evolutionary secrets.|The Doctor (Seventh Doctor);Ace
EOF

echo "Ensuring known episodes..."
existing_eps=$(seed_api_get "$API/shows/$SHOW_ID/episodes")
printf '%s\n' "$EPISODES" | while IFS='|' read -r season air_date title description chars; do
  [ -z "$season" ] && continue
  if echo "$existing_eps" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | length > 0' >/dev/null; then
    echo "  Episode exists (S${season}): $title"
  else
    echo "  Creating episode (S${season}): $title"
    jq -nc --argjson season "$season" --arg date "$air_date" --arg t "$title" --arg d "$description" '{season_number:$season, air_date:$date, title:$t, description:$d}' | seed_api_post "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d @- >/dev/null
  fi

  EP_ID=$(seed_api_get "$API/shows/$SHOW_ID/episodes" | jq -r --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | (.[0].id // empty)')
  [ -z "$EP_ID" ] && { echo "  Could not resolve episode id for season $season"; continue; }

  if [ -n "$chars" ]; then
    echo "$chars" | tr ';' '\n' | while IFS= read -r c; do
      [ -z "$c" ] && continue
      echo "    + $c"
      seed_api_post "$API/episodes/$EP_ID/characters" -H 'Content-Type: application/json' -d "$(jq -nc --arg n "$c" '{character_name:$n}')" >/dev/null
    done
  fi
done

# --- create placeholder episodes to match IMDb counts ---
echo "Ensuring additional episodes..."
for season in $(seq 1 26); do
  total="$(lookup_epcount "$season" || true)"
  [ -z "$total" ] && continue
  y="$(lookup_year "$season" || true)"
  existing_count=$(seed_api_get "$API/shows/$SHOW_ID/seasons/$season/episodes" | jq 'length')
  if [ "$existing_count" -ge "$total" ]; then
    echo "Season $season already has $existing_count episodes"
    continue
  fi
  for ep in $(seq $((existing_count+1)) "$total"); do
    title="S${season}E${ep}"
    air_date=$(date -d "${y:-1900}-01-01 +$((ep-1)) weeks" +%Y-%m-%d 2>/dev/null || printf "%s-01-01" "${y:-1900}")
    description="Episode ${ep} of season ${season}."
    if seed_api_get "$API/shows/$SHOW_ID/episodes" | jq -e --arg t "$title" --argjson s "$season" 'map(select(.season_number == $s and .title == $t)) | length > 0' >/dev/null; then
      echo "  Episode exists (S${season}E${ep}): $title"
    else
      echo "  Creating episode (S${season}E${ep}): $title"
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
