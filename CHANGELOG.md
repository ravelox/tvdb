# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2025-09-23
### Added
- POST `/admin/reset-database` endpoint to drop and reinitialize the schema via the API.
- API smoke test coverage for the admin reset workflow.

### Changed
- `reset_database.sh` now calls the admin API instead of executing SQL locally.
- README, OpenAPI spec, Postman collection, Docker, Helm, and Kubernetes defaults bumped to 1.2.0.

## [1.1.0] - 2025-09-22
### Changed
- Adopted a semantic version baseline of 1.1.0 across the package, specs, and deployment assets.
- Added automated build numbering to the Docker helper and image metadata so each rebuild gets a unique tag.

## [1.0.11] - 2025-09-20
### Added
- Documented API uninstall/cleanup steps in the README.
### Changed
- Bumped package, OpenAPI spec, Postman collection, Docker, Helm chart, and Kubernetes deployment versions to 1.0.11.

## [1.0.10] - 2025-09-16
### Changed
- Bumped package, OpenAPI spec, Postman collection, Docker, Helm chart, and Kubernetes deployment versions to 1.0.10.

## [1.0.9] - 2025-09-13
### Changed
- Bumped package, Postman collection, and spec versions to 1.0.9.
- Log lines now include the version prefix.

## [1.0.8] - 2025-09-04
### Changed
- Bumped package, Docker Compose, Postman collection, and spec versions to 1.0.8.

## [1.0.7] - 2025-09-03
### Added
- GraphQL endpoints mirroring existing REST resources.
- Exposed GraphQL discovery endpoint.
### Changed
- Bumped package, Postman collection, and spec versions to 1.0.7.

## [1.0.6] - 2025-08-28
### Added
- Support for nested sub-resource retrieval via `include` parameter.
- Tests covering `include` query usage.
- OpenAPI spec and Postman collection updated.
- README curl examples for `start`, `end`, and `include` query parameters.
### Changed
- Bumped package and spec versions to 1.0.6.

## [1.0.5] - 2025-08-12
### Added
- Query jobs duplicated for seasons, episodes, characters, and actors.
### Changed
- OpenAPI `info.version` and package version bumped to 1.0.5.

## [1.0.4] - 2025-08-12
### Added
- `CHANGELOG.md` with version history.
- Packaging now includes changelog.

### Fixed
- **Seed script:** corrected a stray `\n` sequence in the EPISODES block between seasons 12 and 13 so each episode is on its own line.

### Notes
- No schema changes; OpenAPI `info.version` bumped to 1.0.4; `package.json` bumped to 1.0.4.

## [1.0.3] - 2025-08-12
### Added
- README now contains a comprehensive cURL cookbook covering all endpoints, including season-episodes routes.

### Changed
- OpenAPI `info.version` set to 1.0.3; `package.json` bumped to 1.0.3.

## [1.0.2] - 2025-08-12
### Added
- New endpoints to list episodes within a season:
  - `GET /seasons/:id/episodes`
  - `GET /shows/:showId/seasons/:seasonNumber/episodes`
- OpenAPI paths updated accordingly.
- Packaged archive with updates.

## [1.0.1] - 2025-08-12
### Fixed
- Removed accidental leading `\` characters from generated files.
- Bumped version in `package.json` to 1.0.1.

## [1.0.0] - 2025-08-12
### Added
- Initial implementation: CRUD for shows, seasons, episodes, characters, actors.
- Episode↔Character many-to-many links.
- Simulated long-running query jobs with polling + downloadable results.
- DB auto-initialization from `schema.sql`.
- OpenAPI discovery at `/openapi.json` and optional Swagger UI at `/docs`.
