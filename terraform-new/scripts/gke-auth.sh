#!/usr/bin/env bash

set -euo pipefail

mode="${1:---exec-credential}"
token=""

if command -v gcloud >/dev/null 2>&1; then
  if candidate="$(gcloud auth print-access-token --quiet 2>/dev/null)" &&
    [[ -n "$candidate" ]]; then
    token="$candidate"
  fi
fi

if [[ -z "$token" ]]; then
  command -v curl >/dev/null 2>&1 || {
    printf 'error: neither usable gcloud credentials nor curl are available\n' >&2
    exit 1
  }

  metadata_response="$(
    curl --fail --silent --show-error \
      --noproxy metadata.google.internal \
      --header 'Metadata-Flavor: Google' \
      http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token
  )"
  token="$(
    printf '%s' "$metadata_response" |
      sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  )"
fi

[[ -n "$token" ]] || {
  printf 'error: unable to obtain a Google access token\n' >&2
  exit 1
}

case "$mode" in
  --token)
    printf '%s\n' "$token"
    ;;
  --exec-credential)
    printf '%s\n' \
      '{"apiVersion":"client.authentication.k8s.io/v1beta1","kind":"ExecCredential","status":{"token":"'"$token"'"}}'
    ;;
  *)
    printf 'error: unsupported mode: %s\n' "$mode" >&2
    exit 1
    ;;
esac
