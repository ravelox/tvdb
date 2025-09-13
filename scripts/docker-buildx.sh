#!/usr/bin/env bash
set -euo pipefail

docker buildx build --platform linux/arm/v7,linux/arm64,linux/amd64 \
  -t ravelox/tvdb:latest \
  -t ravelox/tvdb:${npm_package_version} \
  --push .

