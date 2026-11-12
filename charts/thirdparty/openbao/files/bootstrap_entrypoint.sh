#!/bin/sh
set -eu

# The SDK image bundles Python without exposing python3 on PATH. Use the
# interpreter reported by the SDK itself, then expose it to bootstrap.sh too.
bootstrap_python="$(gcloud info --format='value(basic.python_location)')"
case "$bootstrap_python" in
  /*) ;;
  *) printf '%s\n' 'OpenBao bootstrap could not resolve the SDK Python runtime.' >&2; exit 1 ;;
esac
if [ ! -x "$bootstrap_python" ]; then
  printf '%s\n' 'OpenBao bootstrap Python runtime is not executable.' >&2
  exit 1
fi
export CLOUDSDK_PYTHON="$bootstrap_python"
PATH="${bootstrap_python%/*}:$PATH"
export PATH
for bootstrap_tool in python3 curl bash gcloud; do
  if ! command -v "$bootstrap_tool" >/dev/null 2>&1; then
    printf 'OpenBao bootstrap runtime is missing %s.\n' "$bootstrap_tool" >&2
    exit 1
  fi
done
exec "$bootstrap_python" "$@"
