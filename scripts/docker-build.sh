#!/usr/bin/env bash
set -euo pipefail

platforms="linux/arm/v7,linux/arm64,linux/amd64"
builder="tvdb-multiarch"

# Ensure a docker-container builder is available
if ! docker buildx inspect "$builder" >/dev/null 2>&1; then
  docker buildx create --name "$builder" --driver docker-container --use
else
  docker buildx use "$builder"
fi

docker buildx inspect --bootstrap

docker buildx build --platform "$platforms" \
  -t ravelox/tvdb:latest \
  -t ravelox/tvdb:${npm_package_version} \
  --push .
