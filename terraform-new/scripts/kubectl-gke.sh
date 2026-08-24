#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KUBE_SERVER:?KUBE_SERVER is required}"
: "${KUBE_CA_CERTIFICATE:?KUBE_CA_CERTIFICATE is required}"

[[ "$KUBE_SERVER" == https://* ]] || {
  printf 'error: KUBE_SERVER must use HTTPS\n' >&2
  exit 1
}
command -v kubectl >/dev/null 2>&1 || {
  printf 'error: kubectl is required\n' >&2
  exit 1
}

temporary_directory="$(mktemp -d)"
ca_file="$temporary_directory/cluster-ca.crt"
kubeconfig_file="$temporary_directory/kubeconfig"
cleanup() {
  rm -f "$ca_file" "$kubeconfig_file"
  rmdir "$temporary_directory"
}
trap cleanup EXIT

if printf '%s' "$KUBE_CA_CERTIFICATE" | base64 --decode >"$ca_file" 2>/dev/null; then
  :
elif printf '%s' "$KUBE_CA_CERTIFICATE" | base64 -D >"$ca_file" 2>/dev/null; then
  :
else
  printf 'error: KUBE_CA_CERTIFICATE is not valid base64\n' >&2
  exit 1
fi
chmod 0600 "$ca_file"

cat >"$kubeconfig_file" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: target
    cluster:
      server: "$KUBE_SERVER"
      certificate-authority: "$ca_file"
contexts:
  - name: target
    context:
      cluster: target
      user: google
current-context: target
users:
  - name: google
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: /usr/bin/env
        args:
          - bash
          - "$SCRIPT_DIR/gke-auth.sh"
          - --exec-credential
        interactiveMode: Never
EOF
chmod 0600 "$kubeconfig_file"

kubectl --kubeconfig="$kubeconfig_file" "$@"
