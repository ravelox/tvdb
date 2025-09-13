# Node.js + MySQL TV Shows CRUD API (with Episode-Character M2M + Jobs + OpenAPI)

This project implements:
- CRUD for shows, seasons, episodes, characters, and actors
- Many-to-many: associate characters with episodes via `episode_characters`
- Simulated long-running job queries with polling + downloadable results
- Auto DB initialization on start (runs `schema.sql`)
- **API discovery** via OpenAPI at `/openapi.json` (+ optional Swagger UI at `/docs`)
- **GraphQL endpoint** at `/graphql` mirroring CRUD operations and jobs
- **GraphQL discovery** at `/graphql.json` (also `/.well-known/graphql.json`)
- **Season episodes endpoints:** `GET /seasons/:id/episodes` and `GET /shows/:showId/seasons/:seasonNumber/episodes`

## Quick start
```bash
npm install
cp .env.example .env   # set your MySQL creds
npm start
curl -s http://localhost:3000/health | jq .
```

### Docker multi-arch build
```bash
npm run docker:build
```
Builds and pushes images for x86_64, arm64, and armv7 using `docker buildx`.

### Render the Helm chart
```bash
helm template tvdb charts/tvdb
```
Renders the Kubernetes manifests from `charts/tvdb` without installing the chart. Use `-f my-values.yaml` to supply custom values.

### Deploy the Helm chart
```bash
helm install tvdb charts/tvdb
```
Installs the manifests into your cluster using the current Kubernetes context. Use `-f my-values.yaml` or `--set key=value` to customize the deployment. For idempotent upgrades, run `helm upgrade --install`.

If installation fails because a `tvdb-storage-pv` volume already exists without Helm labels, either delete it or add the required metadata so Helm can take ownership:

```bash
kubectl label pv tvdb-storage-pv app.kubernetes.io/managed-by=Helm
kubectl annotate pv tvdb-storage-pv meta.helm.sh/release-name=tvdb meta.helm.sh/release-namespace=default
```

Replace `default` if you are installing into a different namespace.

### OpenAPI & Docs
- JSON spec: `GET /openapi.json` (also `/spec` and `/.well-known/openapi.json`)
- Swagger UI (optional): `npm i swagger-ui-express` then open `http://localhost:3000/docs`

### Seed classic Doctor Who
```bash
chmod +x seed_doctor_who.sh
./seed_doctor_who.sh
```
Seeds seasons 1–26, a subset of actors & characters, one opener episode per season, **and links characters** to each opener.

---

## Comprehensive cURL Test Cookbook

> Assumes your API runs at `http://localhost:3000` and you have `jq` installed.
> You can set a base URL once: `export API=http://localhost:3000`

### Health & Initialization
```bash
curl -s -X POST "$API/init" | jq .
curl -s "$API/health" | jq .
```

### OpenAPI discovery
```bash
curl -s "$API/openapi.json" | jq .info
curl -s "$API/spec" | jq .info
curl -s "$API/.well-known/openapi.json" | jq .info
```

### GraphQL discovery
```bash
curl -s "$API/graphql.json" | jq .
curl -s "$API/.well-known/graphql.json" | jq .
```

### GraphQL queries
All REST functionality is also exposed via a lightweight GraphQL endpoint at `/graphql`.
```bash
# Health check
curl -s -X POST "$API/graphql" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ health { ok db } }"}' | jq .

# Create an actor via mutation
curl -s -X POST "$API/graphql" \
  -H 'Content-Type: application/json' \
  -d '{"query":"mutation { createActor(name:\"Sarah Jane\") { id name } }"}' | jq .

# Fetch a show with nested seasons and episodes
curl -s -X POST "$API/graphql" \
  -H 'Content-Type: application/json' \
  -d '{"query":"{ show(id:1) { title seasons { season_number episodes { title } } } }"}' | jq .
```

### Actors
```bash
ACTOR_ID=$(curl -s -X POST "$API/actors" -H 'Content-Type: application/json' -d '{"name":"Tom Baker"}' | jq -r '.id'); echo "$ACTOR_ID"
curl -s "$API/actors" | jq .
curl -s "$API/actors/$ACTOR_ID" | jq .
curl -s -X PUT "$API/actors/$ACTOR_ID" -H 'Content-Type: application/json' -d '{"name":"Thomas Baker"}' | jq .
# curl -i -X DELETE "$API/actors/$ACTOR_ID"
```

### Shows
```bash
SHOW_ID=$(curl -s -X POST "$API/shows" -H 'Content-Type: application/json' -d '{"title":"Doctor Who","description":"BBC sci‑fi","year":1963}' | jq -r '.id'); echo "$SHOW_ID"
curl -s "$API/shows" | jq .
curl -s "$API/shows/$SHOW_ID" | jq .
curl -s -X PUT "$API/shows/$SHOW_ID" -H 'Content-Type: application/json' -d '{"title":"Doctor Who","description":"Classic era","year":1963}' | jq .
# curl -i -X DELETE "$API/shows/$SHOW_ID"
```

### Filtering & nested resources
```bash
# Only shows created in 2024
curl -s "$API/shows?start=2024-01-01T00:00:00Z&end=2024-12-31T23:59:59Z" | jq .
# Fetch a show with seasons, episodes, and characters embedded
curl -s "$API/shows/$SHOW_ID?include=seasons,seasons.episodes,seasons.episodes.characters" | jq .

# Only episodes created in 2024
curl -s "$API/episodes?start=2024-01-01T00:00:00Z&end=2024-12-31T23:59:59Z" | jq .
# Fetch episodes with character+actor data embedded
curl -s "$API/episodes?include=characters,characters.actor" | jq .

# Only actors created in 2024
curl -s "$API/actors?start=2024-01-01T00:00:00Z&end=2024-12-31T23:59:59Z" | jq .
# Fetch an actor with their characters and shows embedded
curl -s "$API/actors/$ACTOR_ID?include=characters,characters.show" | jq .
```

### Seasons
```bash
SEASON_ID=$(curl -s -X POST "$API/shows/$SHOW_ID/seasons" -H 'Content-Type: application/json' -d '{"season_number":12, "year":1974}' | jq -r '.id'); echo "$SEASON_ID"
curl -s "$API/shows/$SHOW_ID/seasons" | jq .
curl -s "$API/seasons/$SEASON_ID" | jq .
curl -s -X PUT "$API/seasons/$SEASON_ID" -H 'Content-Type: application/json' -d '{"season_number":12, "year":1975}' | jq .
# curl -i -X DELETE "$API/seasons/$SEASON_ID"
```

### Episodes (per show + per season)
```bash
EPISODE_ID=$(curl -s -X POST "$API/shows/$SHOW_ID/episodes" -H 'Content-Type: application/json' -d '{"season_number":12, "air_date":"1974-12-28", "title":"Robot", "description":"Season 12 opener."}' | jq -r '.id'); echo "$EPISODE_ID"
curl -s "$API/shows/$SHOW_ID/episodes" | jq .
curl -s "$API/seasons/$SEASON_ID/episodes" | jq .
curl -s "$API/shows/$SHOW_ID/seasons/12/episodes" | jq .
curl -s "$API/episodes/$EPISODE_ID" | jq .
curl -s -X PUT "$API/episodes/$EPISODE_ID" -H 'Content-Type: application/json' -d '{"title":"Robot (Part 1)", "season_number":12}' | jq .
# curl -i -X DELETE "$API/episodes/$EPISODE_ID"
```

### Characters
```bash
CHAR_ID=$(curl -s -X POST "$API/shows/$SHOW_ID/characters" -H 'Content-Type: application/json' -d "{"name":"The Doctor (Fourth Doctor)", "actor_id": $ACTOR_ID}" | jq -r '.id'); echo "$CHAR_ID"
ALT_CHAR_ID=$(curl -s -X POST "$API/shows/$SHOW_ID/characters" -H 'Content-Type: application/json' -d '{"name":"Sarah Jane Smith", "actor_name":"Elisabeth Sladen"}' | jq -r '.id'); echo "$ALT_CHAR_ID"
curl -s "$API/shows/$SHOW_ID/characters" | jq .
curl -s "$API/characters/$CHAR_ID" | jq .
curl -s -X PUT "$API/characters/$CHAR_ID" -H 'Content-Type: application/json' -d '{"name":"The Doctor (4)", "actor_name":"Tom Baker"}' | jq .
# curl -i -X DELETE "$API/characters/$CHAR_ID"
```

### Episode ↔ Character links
```bash
curl -s -X POST "$API/episodes/$EPISODE_ID/characters" -H 'Content-Type: application/json' -d "{"character_id": $CHAR_ID}" | jq .
curl -s -X POST "$API/episodes/$EPISODE_ID/characters" -H 'Content-Type: application/json' -d '{"character_name":"K9", "actor_name":"John Leeson"}' | jq .
curl -s "$API/episodes/$EPISODE_ID/characters" | jq .
curl -i -X DELETE "$API/episodes/$EPISODE_ID/characters/$CHAR_ID"
```

### Simulated long‑running query jobs
Supports shows, seasons, episodes, characters, and actors.
```bash
JOB_ID=$(curl -s -X POST "$API/shows/query-jobs" -H 'Content-Type: application/json' -d '{"title":"Doctor","year_min":1900,"year_max":2100,"delay_ms":2500}' | jq -r '.job_id'); echo "$JOB_ID"
curl -s "$API/jobs/$JOB_ID" | jq .
curl -s -L "$API/jobs/$JOB_ID/download" -o shows_query_${JOB_ID}.json && jq . shows_query_${JOB_ID}.json | head
curl -i -X DELETE "$API/jobs/$JOB_ID"
# Endpoints also exist at /seasons/query-jobs, /episodes/query-jobs, /characters/query-jobs, and /actors/query-jobs
```

### Changelog
See `CHANGELOG.md`.
