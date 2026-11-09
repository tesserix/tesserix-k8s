#!/usr/bin/env bash
set -euo pipefail
chart=${1:?usage: build-chart-dependency.sh CHART}
log=$(mktemp)
trap 'rm -f "$log"' EXIT
attempt=1
while :; do
  if helm dependency build "$chart" >"$log" 2>&1; then
    cat "$log"
    exit 0
  else
    status=$?
  fi
  cat "$log" >&2
  if (( attempt >= 3 )) || ! grep -Eqi '429 Too Many Requests|500 Internal Server Error|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout|TLS handshake timeout|i/o timeout|connection reset by peer|unexpected EOF|context deadline exceeded' "$log"; then
    exit "$status"
  fi
  delay=$(( (1 << (attempt - 1)) + RANDOM % 2 ))
  printf 'Transient dependency failure for %s; retrying in %ss (attempt %s/3).\n' "$chart" "$delay" "$((attempt + 1))" >&2
  sleep "$delay"
  attempt=$((attempt + 1))
done
