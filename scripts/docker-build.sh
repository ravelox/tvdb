#!/usr/bin/env bash
set -euo pipefail

platforms="linux/arm/v7,linux/arm64,linux/amd64"
builder="tvdb-multiarch"
node_version="20.12.2-slim"
push_image=false
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"

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

cd "$repo_dir"

if [[ -n "${npm_package_version:-}" ]]; then
  app_version="$npm_package_version"
else
  app_version="$(node -p "require('${repo_dir}/package.json').version")"
fi

build_number_file="${repo_dir}/.docker-build-number"
if [[ -f "$build_number_file" ]]; then
  if ! read -r previous_build_number <"$build_number_file"; then
    previous_build_number=0
  fi
else
  previous_build_number=0
fi

if [[ "$previous_build_number" =~ ^[0-9]+$ ]]; then
  next_build_number=$((previous_build_number + 1))
else
  next_build_number=1
fi

printf '%s\n' "$next_build_number" >"$build_number_file"

full_version="${app_version}.${next_build_number}"

echo "Building ravelox/tvdb:${full_version} (base ${app_version}, build #${next_build_number})"

build_args=(
  docker buildx build
  --platform "$platforms"
  --build-arg NODE_VERSION="$node_version"
  --build-arg APP_VERSION="$app_version"
  --build-arg BUILD_NUMBER="$next_build_number"
  -t ravelox/tvdb:latest
  -t ravelox/tvdb:"$app_version"
  -t ravelox/tvdb:"$full_version"
)

if $push_image; then
  build_args+=(--push)
else
  build_args+=(--load)
fi

"${build_args[@]}" .
