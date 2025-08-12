# Node.js + MySQL TV Shows CRUD API (with Episode-Character M2M + Jobs + OpenAPI)

This project implements:
- CRUD for shows, seasons, episodes, characters, and actors
- Many-to-many: associate characters with episodes via `episode_characters`
- Simulated long-running job queries with polling + downloadable results
- Auto DB initialization on start (runs `schema.sql`)
- **API discovery** via OpenAPI at `/openapi.json` (+ optional Swagger UI at `/docs`)

## Quick start
```bash
npm install
cp .env.example .env   # set your MySQL creds
npm start
curl -s http://localhost:3000/health | jq .
```

### OpenAPI & Docs
- JSON spec: `GET /openapi.json` (also `/spec` and `/.well-known/openapi.json`)
- Swagger UI (optional): `npm i swagger-ui-express` then open `http://localhost:3000/docs`

### Seed classic Doctor Who
```bash
chmod +x seed_doctor_who.sh
./seed_doctor_who.sh
```
Seeds seasons 1–26, a subset of actors & characters, one opener episode per season, **and links characters** to each opener.

### cURL Cookbook
See the canvas doc or use the endpoints directly with curl.
