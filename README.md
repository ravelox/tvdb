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

### Environment configuration

The server reads a handful of environment variables so you can mirror the production deployment locally.

**Core service settings**

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `3000` | HTTP port for the Express server. |
| `DB_HOST` | `localhost` | MySQL host name. |
| `DB_PORT` | `3306` | MySQL port. |
| `DB_USER` | `root` | Database user used for schema initialization and pool connections. |
| `DB_PASSWORD` | _empty string_ | Database password. |
| `DB_NAME` | `tvdb` | Database/schema name created on startup. |
| `DB_RETRY_ATTEMPTS` | `3` | Number of times database operations are retried after fatal connection errors. |
| `DB_RETRY_DELAY_MS` | `200` | Delay (ms) between retry attempts. |
| `APP_VERSION` | package version | Overrides the version tag emitted in logs and `/deployment-version`. |
| `BUILD_NUMBER` | _unset_ | Optional numeric suffix appended to the version tag. |

**Authentication & admin UI**

| Variable | Default | Description |
| --- | --- | --- |
| `ENABLE_ADMIN_UI` | `true` in non-production, `false` otherwise | Controls whether the `/admin` console is served. |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | _unset_ | If both are provided, `/admin` is protected with HTTP Basic Auth. |
| `API_TOKEN` | _unset_ | When set, all JSON/GraphQL endpoints require the token via the `x-api-token` header or a `Bearer` authorization header. |

> `/deployment-version` is intentionally left unauthenticated so load balancers and uptime checks can read the running build metadata even when the rest of the API is locked down with `API_TOKEN`.

**Background job retention**

| Variable | Default | Description |
| --- | --- | --- |
| `JOB_TTL_MS` | `600000` | Time (ms) before completed/failed job results expire. Set to `0` to retain indefinitely. |
| `MAX_JOB_HISTORY` | `100` | Maximum number of job records kept in memory before the oldest entries are evicted. |

See `.env.example` for a compose-ready set of defaults—the seed scripts automatically source it so tokens and host overrides apply everywhere.

### TV Explorer web app

The repository ships with a standalone client experience at [`/explorer`](http://localhost:3000/explorer/) that consumes the same REST API as the admin console. The page is compiled from static assets under `public/explorer` and offers:

- Token-based authentication: when `API_TOKEN` is set, the app prompts for the token and stores it in the browser's `localStorage`. You can re-enter or clear the token at any time with the **Change API Token** button in the header.
- Cascading dropdown navigation: pick a show, then drill into its seasons, episodes, and characters with keyboard-friendly select menus and focused detail panes.
- Character overviews: every show's characters (and their actors, when known) are displayed alongside the season/episode explorer.
- Deployment awareness: the header surfaces the running application version/build using the `/deployment-version` endpoint so you can verify what you're testing.

Start the server (`npm start`) and open the `/explorer` route in a browser to try it out.

### Uninstall / Cleanup

When you're done experimenting you can tear everything down:

- **Local Node.js install:** stop `npm start` (Ctrl+C), delete the install artifacts with `rm -rf node_modules package-lock.json`, and drop the schema the API created by connecting to MySQL and running `DROP DATABASE <your DB_NAME>;` (the default is `tvdb`).
- **Docker Compose:** run `docker compose down -v` to stop the stack and remove the bind-mounted database volume.
- **Helm release:** run `helm uninstall tvdb -n tvdb` (or your namespace) and, if you created persistent volumes, clean them up with `kubectl delete pvc -n <namespace> -l app=tvdb`.

### Docker multi-arch build
```bash
npm run docker:build
# publish multi-arch images
npm run docker:build -- --push
```
By default the helper script builds an x86_64 image locally (loaded into your Docker daemon). Pass `--push` to publish the multi-architecture image set.

Each run increments a local `.docker-build-number` counter and tags the image with the semantic package version (for example `1.7.0`) plus a numeric suffix such as `1.7.0.7`. Set the optional `APP_VERSION`/`BUILD_NUMBER` build arguments (or the matching environment variables consumed by `docker-compose.yaml`) if you need to override either value manually.

### Release automation

Version bumps are published automatically once they land on `main`. The **Release on version bump** GitHub Actions workflow reads the `version` field from `package.json`, tags the commit as `v<version>`, and creates a GitHub release with autogenerated notes. Pushes that do not change the `version` field simply skip the release job.

### Helm deployment
Render the manifests without installing:
```bash
helm template tvdb charts/tvdb
```
Install (or upgrade) the release. If the `tvdb` namespace doesn't exist, choose one of the following:

Option 1: create the namespace manually:
```bash
kubectl create namespace tvdb
helm install tvdb charts/tvdb -f charts/tvdb/values.yaml --namespace tvdb
```

Option 2: let Helm create the namespace automatically:
```bash
helm install tvdb charts/tvdb -f charts/tvdb/values.yaml --namespace tvdb --create-namespace
```

To upgrade and ensure the namespace exists:
```bash
helm upgrade --install tvdb charts/tvdb -n tvdb --create-namespace
```
If the install fails with a message like:
```
PersistentVolume "tvdb-storage-pv" ... missing key "app.kubernetes.io/managed-by"
```
label and annotate the existing volume so Helm can manage it and retry the install:
```bash
kubectl label pv tvdb-storage-pv app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate pv tvdb-storage-pv meta.helm.sh/release-name=tvdb meta.helm.sh/release-namespace=tvdb --overwrite
```
Use `-f my-values.yaml` or `--set key=value` to customize any of the values.

> **Secrets:** The chart expects either an existing Kubernetes secret (see `storage.existingSecret` / `app.existingSecret`) or plain values for `storage.password` and optional admin credentials. Sample manifests for manual deployments live under `k8s/` (e.g. `k8s/tvdb-secrets.yaml.example`).

### OpenAPI & Docs
- JSON spec: `GET /openapi.json` (also `/spec` and `/.well-known/openapi.json`)
- Swagger UI (optional): `npm i swagger-ui-express` then open `http://localhost:3000/docs`

### Seed classic Doctor Who
```bash
chmod +x seed_doctor_who.sh
./seed_doctor_who.sh
```
Seeds seasons 1–26, a subset of actors & characters, one opener episode per season, **and links characters** to each opener.

### Seed Sapphire & Steel

```bash
chmod +x seed_sapphire_and_steel.sh
./seed_sapphire_and_steel.sh
```

Seeds ITV's *Sapphire & Steel* with six seasons of story arcs, creates the principal cast, and links each episode's characters to their matching actors. All seed scripts source `scripts/seed_common.sh`, which loads `$API_TOKEN` from `.env` (if present) and automatically retries requests while the API or database warms up.

### Reset the database
```bash
./reset_database.sh       # prompts before dropping data
./reset_database.sh --force  # skip the confirmation prompt
```
Targets the running API at `$API_BASE_URL` (default `http://localhost:$PORT`) and
invokes `POST /admin/reset-database` using the optional `$API_TOKEN` header.
Make sure the server is running so reseed scripts start from an empty database.

---

## Comprehensive cURL Test Cookbook

> Assumes your API runs at `http://localhost:3000` and you have `jq` installed.
> You can set a base URL once: `export API=http://localhost:3000`

### Health & Initialization
```bash
curl -s -X POST "$API/init" | jq .
curl -s "$API/health" | jq .
curl -s "$API/deployment-version" | jq .
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

### Pagination on list endpoints
All collection `GET` endpoints accept optional `limit` and `offset` query parameters in addition to the existing `start`, `end`, and `include` filters. Use `limit` to cap the number of rows returned and `offset` (requires `limit`) to skip a number of rows before results begin.

```bash
# Fetch five shows starting at the sixth row, ordered the same way as the default response
curl -s "$API/shows?limit=5&offset=5" | jq .

# Page through characters linked to a specific episode
curl -s "$API/episodes/1/characters?limit=10&offset=10" | jq .
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
