#!/usr/bin/env bash
set -euo pipefail

platforms="linux/arm/v7,linux/arm64,linux/amd64"
builder="tvdb-multiarch"
node_version="20.12.2-slim"
push_image=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)
      push_image=true
      ;;
    --platforms)
      shift
      platforms="$1"
      ;;
    --node-version)
      shift
      node_version="$1"
      ;;
    --help|-h)
      echo "Usage: $0 [--push] [--platforms <list>] [--node-version <version>]" >&2
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--push] [--platforms <list>] [--node-version <version>]" >&2
      exit 1
      ;;
  esac
  shift
done

if ! $push_image && [[ "$platforms" == *","* ]]; then
  echo "Multi-platform builds require --push. Use --push or specify a single platform." >&2
  exit 1
fi

# Ensure a docker-container builder is available
if ! docker buildx inspect "$builder" >/dev/null 2>&1; then
  docker buildx create --name "$builder" --driver docker-container --use
else
  docker buildx use "$builder"
fi

docker buildx inspect --bootstrap

build_args=(
  docker buildx build
  --platform "$platforms"
  --build-arg NODE_VERSION="$node_version"
  -t ravelox/tvdb:latest
  -t ravelox/tvdb:${npm_package_version}
)

if $push_image; then
  build_args+=(--push)
else
  build_args+=(--load)
fi

"${build_args[@]}" .
