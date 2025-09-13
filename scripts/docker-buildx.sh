#!/usr/bin/env bash
set -euo pipefail

# Some Docker installations do not support the --platform flag.  If the
# flag is unavailable we fall back to building for the host platform only.
platforms="linux/arm/v7,linux/arm64,linux/amd64"

if docker buildx build --help 2>&1 | grep -q -- '--platform'; then
  docker buildx build --platform "$platforms" \
    -t ravelox/tvdb:latest \
    -t ravelox/tvdb:${npm_package_version} \
    --push .
else
  docker buildx build \
    -t ravelox/tvdb:latest \
    -t ravelox/tvdb:${npm_package_version} \
    --push .
fi

