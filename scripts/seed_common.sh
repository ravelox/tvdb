#!/usr/bin/env bash

# Shared helpers for the TVDB seed scripts. The functions here wrap curl with
# retry logic so the scripts can tolerate temporary database outages or startup
# races while the API is still wiring up its MySQL connection.

: "${API:=http://localhost:3000}"

# How many times to retry a request that fails due to network errors, 5xx
# responses, or known database connectivity messages.
SEED_MAX_RETRIES=${SEED_MAX_RETRIES:-10}
# Base delay (in seconds) between retries. The delay increases linearly with
# each attempt to give the database a chance to recover.
SEED_RETRY_DELAY=${SEED_RETRY_DELAY:-2}

# Captures the HTTP status from the most recent call to seed_api_request and
# friends. Scripts can inspect this (e.g., to treat a missing /init endpoint as
# non-fatal).
SEED_HTTP_STATUS=0

seed__normalize_url() {
  local raw="$1"
  if [[ "$raw" =~ ^https?:// ]]; then
    printf '%s' "$raw"
  elif [[ "$raw" == /* ]]; then
    printf '%s%s' "$API" "$raw"
  else
    printf '%s/%s' "$API" "$raw"
  fi
}

seed__should_retry() {
  local exit_code="$1"
  local status="$2"
  local body="$3"

  if (( exit_code != 0 )); then
    return 0
  fi

  if [[ "$status" =~ ^5 ]]; then
    return 0
  fi

  if printf '%s' "$body" | grep -qiE 'connect (?:econn|etimedout)|connection refused|database .*unavailable|pool is closed'; then
    return 0
  fi

  return 1
}

seed_api_request() {
  if (( $# < 2 )); then
    echo "seed_api_request requires a method and URL" >&2
    return 1
  fi

  local method="$1"
  shift
  local url
  url=$(seed__normalize_url "$1")
  shift

  local attempt=1
  local status="000"
  local exit_code=0
  local body=""

  while (( attempt <= SEED_MAX_RETRIES )); do
    local tmp
    tmp=$(mktemp)

    set +e
    status=$(command curl --silent --show-error --request "$method" "$url" "$@" --output "$tmp" --write-out '%{http_code}')
    exit_code=$?
    set -e

    if [[ -s "$tmp" ]]; then
      body=$(cat "$tmp")
    else
      body=""
    fi
    rm -f "$tmp"

    if (( exit_code == 0 )) && [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
      SEED_HTTP_STATUS=$status
      printf '%s' "$body"
      return 0
    fi

    if (( attempt < SEED_MAX_RETRIES )) && seed__should_retry "$exit_code" "$status" "$body"; then
      local sleep_for=$(( SEED_RETRY_DELAY * attempt ))
      local descriptor
      if (( exit_code != 0 )); then
        descriptor="curl exit $exit_code"
      else
        descriptor="HTTP $status"
      fi
      if [[ -n "$body" ]]; then
        descriptor+=" — $(printf '%s' "$body" | head -n1)"
      fi
      echo "Retrying $method $url in ${sleep_for}s (${descriptor})" >&2
      sleep "$sleep_for"
      attempt=$(( attempt + 1 ))
      continue
    fi

    SEED_HTTP_STATUS=$status
    if (( exit_code != 0 )); then
      echo "Request to $url failed with curl exit $exit_code" >&2
    else
      echo "Request to $url failed with status $status" >&2
    fi
    if [[ -n "$body" ]]; then
      echo "$body" >&2
    fi
    return 1
  done

  SEED_HTTP_STATUS=$status
  return 1
}

seed_api_get() { seed_api_request GET "$@"; }
seed_api_post() { seed_api_request POST "$@"; }
seed_api_put() { seed_api_request PUT "$@"; }
seed_api_delete() { seed_api_request DELETE "$@"; }

seed_init_database() {
  local err_file
  err_file=$(mktemp)
  if seed_api_post "$API/init" >/dev/null 2>"$err_file"; then
    echo "[init] Database ensured"
    rm -f "$err_file"
    return 0
  fi

  local status="${SEED_HTTP_STATUS:-}"
  if [[ "$status" == "404" ]]; then
    echo "[init] Skipped or not supported"
    rm -f "$err_file"
    return 0
  fi

  if [[ -s "$err_file" ]]; then
    cat "$err_file" >&2
  fi
  rm -f "$err_file"
  echo "[init] Unable to initialize database (status=${status:-unknown})"
  return 0
}

