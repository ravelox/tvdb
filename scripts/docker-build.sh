#!/usr/bin/env bash
set -euo pipefail

platforms="linux/arm/v7,linux/arm64,linux/amd64"
builder="tvdb-multiarch"
node_version="20.12.2-slim"
push_image=false
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "${script_dir}/.." && pwd)"
repository="${DOCKERHUB_REPOSITORY:-ravelox/tvdb}"
keep_build_tag_count="${DOCKERHUB_KEEP_BUILDS:-2}"

prune_old_build_tags() {
  local repository="$1"
  local app_version="$2"
  local keep_count="${3:-2}"

  if [[ ! "$keep_count" =~ ^[0-9]+$ ]]; then
    echo "Invalid keep count '${keep_count}'; defaulting to 2." >&2
    keep_count=2
  fi

  if (( keep_count < 1 )); then
    keep_count=1
  fi

  local username="${DOCKERHUB_USERNAME:-}"
  local password="${DOCKERHUB_PASSWORD:-${DOCKERHUB_TOKEN:-}}"

  if [[ -z "$username" || -z "$password" ]]; then
    echo "Skipping Docker Hub tag pruning; DOCKERHUB_USERNAME and DOCKERHUB_PASSWORD (or DOCKERHUB_TOKEN) must be set." >&2
    return
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "Skipping Docker Hub tag pruning; jq is required." >&2
    return
  fi

  local login_payload
  login_payload=$(jq -n --arg username "$username" --arg password "$password" '{username:$username, password:$password}')

  local token_response
  if ! token_response=$(curl -fsSL -H "Content-Type: application/json" -d "$login_payload" "https://hub.docker.com/v2/users/login/"); then
    echo "Failed to authenticate with Docker Hub; skipping tag pruning." >&2
    return
  fi

  local token
  token=$(jq -r '.token // empty' <<<"$token_response")

  if [[ -z "$token" ]]; then
    echo "Docker Hub authentication response did not include a token; skipping tag pruning." >&2
    return
  fi

  local api_url="https://hub.docker.com/v2/repositories/${repository}/tags/?page_size=100"
  local tags=()
  local escaped_app_version="${app_version//./\\.}"

  while [[ -n "$api_url" ]]; do
    local page
    if ! page=$(curl -fsSL -H "Authorization: JWT $token" "$api_url"); then
      echo "Failed to fetch Docker Hub tags; skipping tag pruning." >&2
      return
    fi

    while IFS= read -r tag_name; do
      if [[ "$tag_name" =~ ^${escaped_app_version}\.([0-9]+)$ ]]; then
        tags+=("$tag_name:${BASH_REMATCH[1]}")
      fi
    done < <(jq -r '.results[].name' <<<"$page")

    api_url=$(jq -r '.next // empty' <<<"$page")
  done

  if (( ${#tags[@]} <= keep_count )); then
    echo "Docker Hub currently has ${#tags[@]} build tag(s) for ${app_version}; nothing to prune."
    return
  fi

  local sorted_tags=()
  while IFS= read -r line; do
    sorted_tags+=("$line")
  done < <(printf '%s\n' "${tags[@]}" | sort -t: -k2,2nr)

  local keep_tags=()
  for entry in "${sorted_tags[@]:0:keep_count}"; do
    keep_tags+=("${entry%%:*}")
  done

  local deleted=0
  for entry in "${sorted_tags[@]:keep_count}"; do
    local tag="${entry%%:*}"
    local delete_url="https://hub.docker.com/v2/repositories/${repository}/tags/${tag}/"
    if curl -fsSL -X DELETE -H "Authorization: JWT $token" "$delete_url" >/dev/null 2>&1; then
      echo "Deleted old Docker Hub tag ${tag}"
      ((deleted++))
    else
      echo "Failed to delete Docker Hub tag ${tag}" >&2
    fi
  done

  if (( deleted > 0 )); then
    echo "Pruned ${deleted} old Docker Hub build tag(s); kept: ${keep_tags[*]}"
  else
    echo "No Docker Hub tags were pruned."
  fi
}

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

echo "Building ${repository}:${full_version} (base ${app_version}, build #${next_build_number})"

build_args=(
  docker buildx build
  --platform "$platforms"
  --build-arg NODE_VERSION="$node_version"
  --build-arg APP_VERSION="$app_version"
  --build-arg BUILD_NUMBER="$next_build_number"
  -t "${repository}:latest"
  -t "${repository}:${app_version}"
  -t "${repository}:${full_version}"
)

if $push_image; then
  build_args+=(--push)
else
  build_args+=(--load)
fi

"${build_args[@]}" .

if $push_image; then
  prune_old_build_tags "$repository" "$app_version" "$keep_build_tag_count"
fi

echo "Completed build for ${repository}:${full_version}"
