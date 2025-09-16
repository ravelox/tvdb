# AGENTS Guidelines

## Repository-wide setup & workflow
- Document the supported toolchain up front—contributors should install dependencies with `npm install`, start the API with `npm start`, and always run the Node 20 test suite via `npm test` before opening a PR, because those are the only scripts defined in `package.json` and the Docker image is pinned to Node 20.12.2.
- Call out the core environment variables (`PORT`, `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `ENABLE_ADMIN_UI`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`, `API_TOKEN`, and the job-tuning knobs) that `server.js` expects so folks can mirror the production configuration locally.

## Database and schema changes
- Explain that the server automatically boots the schema on startup by reading `schema.sql`, so any migration-like change must update that file and stay compatible with the bootstrap routine in `server.js`’s `initDatabase` helper.
- Encourage updates to the various seed scripts (e.g., `seed_doctor_who.sh`) whenever schema changes would break the sample data flows, and remind contributors that the scripts depend on `curl`, `jq`, and the existing REST endpoints.

## HTTP API updates
- Note that `server.js` is the single source of truth for all Express routes, their validation helpers, and shared utilities like `parseDateRange`, `parseIncludeParam`, `asyncH`, and `httpError`; any new route should follow those patterns for consistency.
- Require that every REST change keeps the built-in OpenAPI descriptor (`openapiBase`), the generated `/openapi.json` response, and the checked-in `openapi.json` file in sync, otherwise the admin UI and documentation drift.

## GraphQL layer
- Mention that GraphQL operations are registered explicitly through `registerOperation` and rely on lightweight resolvers plus `resolveFunctions`, so contributors should register new operations there and return plain objects/functions that match the existing pattern.
- Warn that the custom parser in `lib/graphqlParser.js` intentionally supports only a single root field, no variables, and limited literal syntax; changes that need more GraphQL expressiveness must extend that parser with matching tests.

## Admin UI & client code
- Explain that the admin panel at `public/admin.html`/`public/admin.js` introspects the OpenAPI spec to render forms, so modifications should preserve that auto-generation flow and keep the markup and styling minimal and semantic.

## Documentation & tooling
- Encourage running `node scripts/generate-postman.js` whenever `openapi.json` changes so the bundled Postman collection stays current, because the script reads the spec and rewrites `tvdb.postman_collection.json`.
- Point folks who prefer containers to the `Dockerfile` and `docker-entrypoint.sh`, noting that the entrypoint just execs the command so custom images should respect that contract.

## Testing expectations
- Document that the test suite uses Node’s built-in `node:test` runner, spins up the API in-process with a mocked `mysql2` layer (`test/mock-db.js`), and exercises both REST and GraphQL surfaces, so contributors should keep those contracts stable and expand the tests alongside new features.
