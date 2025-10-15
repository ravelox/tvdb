#!/usr/bin/env bash
# Helper functions for the "unseed" scripts. These utilities rely on
# scripts/seed_common.sh for HTTP helpers and assume API / token discovery
# has already run.

: "${UNSEED_SHOW_LIMIT:=1000}"

_UNSEED_SHOW_CACHE=""

unseed_reset_show_cache() {
  _UNSEED_SHOW_CACHE=""
}

unseed_load_show_cache() {
  if [[ -n "$_UNSEED_SHOW_CACHE" ]]; then
    return 0
  fi
  if ! _UNSEED_SHOW_CACHE=$(seed_api_get "$API/shows?limit=${UNSEED_SHOW_LIMIT}&include=characters,characters.actor" 2>/dev/null); then
    _UNSEED_SHOW_CACHE="[]"
  fi
}

unseed_find_show_id() {
  local title="$1"
  local year="$2"
  local stream
  if ! stream=$(seed_api_get "$API/shows?limit=${UNSEED_SHOW_LIMIT}" 2>/dev/null); then
    echo ""
    return 0
  fi
  printf '%s' "$stream" | jq -r --arg title "$title" --arg year "$year" '
    map(select(.title == $title and ((.year|tostring) == $year))) |
    (.[0].id // empty)
  '
}

unseed_collect_actor_names() {
  local show_id="$1"
  local data
  if ! data=$(seed_api_get "$API/shows/$show_id/characters?include=actor&limit=${UNSEED_SHOW_LIMIT}" 2>/dev/null); then
    return 0
  fi
  printf '%s' "$data" | jq -r '
    map(.actor?.name // .actor_name // empty)
    | map(select(length > 0))
    | unique[]?
  '
}

unseed_delete_show() {
  local show_id="$1"
  local title="$2"
  local year="$3"
  if [ -z "$show_id" ]; then
    echo "No matching show found for '${title}' (${year}); nothing to remove."
    return 0
  fi

  if seed_api_delete "$API/shows/$show_id" >/dev/null 2>&1; then
    echo "Deleted show '${title}' (${year})."
    return 0
  fi

  local status="${SEED_HTTP_STATUS:-}"
  if [[ "$status" == "404" ]]; then
    echo "Show '${title}' (${year}) was already absent."
    return 0
  fi

  echo "Failed to delete show '${title}' (${year}); status=${status:-unknown}" >&2
  return 1
}

unseed_actor_in_use() {
  local actor_name="$1"
  unseed_load_show_cache
  printf '%s\n' "$_UNSEED_SHOW_CACHE" | jq -e --arg name "$actor_name" '
    reduce .[]?.characters[]? as $c
      (false; . or (($c.actor?.name // $c.actor_name // "") == $name))
  ' >/dev/null
}

unseed_delete_actor_if_unused() {
  local actor_name="$1"
  if [ -z "$actor_name" ]; then
    return 0
  fi

  local actors_json
  if ! actors_json=$(seed_api_get "$API/actors?limit=${UNSEED_SHOW_LIMIT}" 2>/dev/null); then
    echo "Unable to enumerate actors; skipping ${actor_name}." >&2
    return 0
  fi

  local actor_id
  actor_id=$(printf '%s' "$actors_json" | jq -r --arg name "$actor_name" '
    map(select(.name == $name)) | (.[0].id // empty)
  ')

  if [ -z "$actor_id" ]; then
    echo "Actor not found (skipping): ${actor_name}"
    return 0
  fi

  if unseed_actor_in_use "$actor_name"; then
    echo "Actor still referenced by another show; keeping ${actor_name}."
    return 0
  fi

  if seed_api_delete "$API/actors/$actor_id" >/dev/null 2>&1; then
    echo "Deleted actor: ${actor_name}"
    return 0
  fi

  local status="${SEED_HTTP_STATUS:-}"
  if [[ "$status" == "404" ]]; then
    echo "Actor already removed: ${actor_name}"
    return 0
  fi

  echo "Failed to delete actor ${actor_name}; status=${status:-unknown}" >&2
  return 1
}

unseed_show() {
  local title="$1"
  local year="$2"
  if [ -z "$title" ]; then
    echo "unseed_show requires a title argument" >&2
    return 1
  fi
  if [ -z "$year" ]; then
    echo "unseed_show requires a year argument" >&2
    return 1
  fi

  local show_id
  show_id=$(unseed_find_show_id "$title" "$year")

  mapfile -t actor_names < <(unseed_collect_actor_names "$show_id")

  if ! unseed_delete_show "$show_id" "$title" "$year"; then
    return 1
  fi

  unseed_reset_show_cache

  for actor_name in "${actor_names[@]}"; do
    unseed_delete_actor_if_unused "$actor_name"
  done

  echo "Unseeded '${title}' (${year})."
}
