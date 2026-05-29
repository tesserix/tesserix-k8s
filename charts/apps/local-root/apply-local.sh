#!/usr/bin/env bash
# Bring up the Tesserix local app-of-apps on the kind sandbox's Argo CD.
#
# Argo in the sandbox syncs from the IN-CLUSTER Gitea (not github), so this
# script: (1) pushes the tesserix-k8s charts to Gitea, (2) renders the app-of-
# apps children pointed at that Gitea repo, (3) kubectl-applies them so Argo
# syncs in sync-wave order (cnpg-operator -> local-infra -> products).
#
#   ./apply-local.sh                                         # push charts + apply infra
#   ./apply-local.sh --set products.devai-api.enabled=true   # also let Argo own a product
#   REPO_URL=<git-url> ./apply-local.sh --no-push            # skip push; use an external repo Argo can read
#
# Prereq: sandbox up (`sandboxctl up --with-cnpg ...`). Uses $KUBECONFIG, else
# ~/.sandboxctl/kubeconfig.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
K8S_REPO="$(cd "$HERE/../../.." && pwd)"                  # tesserix-k8s repo root
# DEFAULT ALWAYS to the local sandbox kubeconfig. We deliberately IGNORE any
# ambient $KUBECONFIG (it may point at a real/prod cluster — e.g. a file named
# gke-devtest). Override only via SANDBOX_KUBECONFIG for a non-standard path.
export KUBECONFIG="${SANDBOX_KUBECONFIG:-$HOME/.sandboxctl/kubeconfig}"
[[ -f "$KUBECONFIG" ]] || { echo "✗ sandbox kubeconfig not found: $KUBECONFIG"; echo "  Run 'sandboxctl up' first, or set SANDBOX_KUBECONFIG=<path>."; exit 1; }

# Gitea coordinates (match sandboxctl defaults).
GITEA_NS="${GITEA_NS:-gitea}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-sandbox}"
GITEA_ORG="${GITEA_ORG:-apps}"
GITEA_REPO="${GITEA_REPO:-tesserix-k8s}"
STATE_DIR="${SANDBOX_STATE_DIR:-$HOME/.sandboxctl}"
GITEA_IN_CLUSTER="http://gitea-http.${GITEA_NS}.svc.cluster.local:3000/${GITEA_ORG}/${GITEA_REPO}.git"

PUSH=1; HELM_ARGS=()
for a in "$@"; do
  case "$a" in
    --no-push) PUSH=0 ;;
    *) HELM_ARGS+=("$a") ;;
  esac
done
REPO_URL="${REPO_URL:-$GITEA_IN_CLUSTER}"
REPO_REV="${REPO_REV:-HEAD}"

# ── SAFETY: LOCAL-ONLY. Refuse to touch anything that isn't a kind/sandbox
# cluster. A mislabeled KUBECONFIG (e.g. a file named gke-devtest that actually
# points at prod) must never let this apply to a real cluster. ──────────────
ctx="$(kubectl config current-context 2>/dev/null || true)"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
if [[ "$ctx" != kind-* && "$ctx" != *sandbox* && "$server" != *127.0.0.1* && "$server" != *localhost* ]]; then
  echo "✗ REFUSING TO RUN — this is a LOCAL-ONLY tool."
  echo "  Current kube context : ${ctx:-<none>}"
  echo "  API server           : ${server:-<none>}"
  echo "  That does not look like a local kind/sandbox cluster (expected context"
  echo "  'kind-*' or '*sandbox*', or a 127.0.0.1/localhost server)."
  echo "  Point KUBECONFIG at the sandbox:  export KUBECONFIG=\$HOME/.sandboxctl/kubeconfig"
  [[ "${ALLOW_NONLOCAL:-}" == "1" ]] || { echo "  (override with ALLOW_NONLOCAL=1 — NOT recommended)"; exit 1; }
  echo "  ALLOW_NONLOCAL=1 set — proceeding against a non-local cluster (dangerous)."
fi

kubectl get ns argocd >/dev/null 2>&1 || {
  echo "!! 'argocd' namespace not found via KUBECONFIG=$KUBECONFIG"
  echo "   Bring the sandbox up first:  sandboxctl up --with-cnpg --podman-disk 80 --podman-memory 12g"
  exit 1
}

# ── 1. Push the tesserix-k8s charts to the in-cluster Gitea (if present) ──────
# Locate Gitea. If the configured namespace is absent, auto-detect by the
# gitea-http Service. If there's no Gitea at all (non-sandboxctl cluster), skip
# the push and let Argo pull from REPO_URL (warn so it's not silent).
if [[ "$PUSH" == "1" ]] && ! kubectl get ns "$GITEA_NS" >/dev/null 2>&1; then
  detected="$(kubectl get svc -A 2>/dev/null | awk '$2=="gitea-http"{print $1; exit}')"
  if [[ -n "$detected" ]]; then
    GITEA_NS="$detected"
    GITEA_IN_CLUSTER="http://gitea-http.${GITEA_NS}.svc.cluster.local:3000/${GITEA_ORG}/${GITEA_REPO}.git"
    echo "==> detected Gitea in namespace '$GITEA_NS'"
  else
    echo "⚠ no in-cluster Gitea found (no 'gitea-http' Service in any namespace)."
    echo "  Skipping the Gitea push. Argo will pull charts from:"
    echo "    repoURL=$REPO_URL"
    echo "  Make sure your Argo can read that repo (public, or a registered repo"
    echo "  credential), or re-run with REPO_URL=<git-url-argo-can-read> --no-push."
    PUSH=0
  fi
fi

if [[ "$PUSH" == "1" ]]; then
  pass_file="$STATE_DIR/gitea-admin-pass"
  [[ -s "$pass_file" ]] || { echo "!! $pass_file missing — is this a sandboxctl cluster? Re-run with --no-push + REPO_URL=<url>"; exit 1; }
  admin_pass="$(cat "$pass_file")"
  kx() { kubectl -n "$GITEA_NS" exec deploy/gitea -c gitea -- sh -c "$1" </dev/null; }

  echo "==> ensuring Gitea org '$GITEA_ORG' + repo '$GITEA_REPO'"
  kx "curl -sf --max-time 5 -u '${GITEA_ADMIN_USER}:${admin_pass}' -H 'Content-Type: application/json' \
        -d '{\"username\":\"${GITEA_ORG}\",\"visibility\":\"public\"}' \
        http://127.0.0.1:3000/api/v1/orgs" >/dev/null 2>&1 || true
  if ! kx "curl -sf --max-time 5 -u '${GITEA_ADMIN_USER}:${admin_pass}' \
            http://127.0.0.1:3000/api/v1/repos/${GITEA_ORG}/${GITEA_REPO}" >/dev/null 2>&1; then
    kx "curl -sf --max-time 10 -u '${GITEA_ADMIN_USER}:${admin_pass}' -H 'Content-Type: application/json' \
          -d '{\"name\":\"${GITEA_REPO}\",\"auto_init\":true,\"default_branch\":\"main\"}' \
          http://127.0.0.1:3000/api/v1/orgs/${GITEA_ORG}/repos" >/dev/null \
      || { echo "!! could not create Gitea repo ${GITEA_ORG}/${GITEA_REPO}"; exit 1; }
  fi

  # Push only charts/ (keeps Argo paths as charts/apps/<x>) over a port-forward.
  tmp="$(mktemp -d -t tesserix-gitea.XXXXXX)"; pf_pid=""
  trap '[[ -n "$pf_pid" ]] && kill "$pf_pid" 2>/dev/null; rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/charts"
  cp -R "$K8S_REPO/charts/apps" "$tmp/charts/apps"
  kubectl -n "$GITEA_NS" port-forward svc/gitea-http 13000:3000 >/dev/null 2>&1 & pf_pid=$!
  for _ in $(seq 1 30); do curl -sf http://127.0.0.1:13000/api/v1/version >/dev/null 2>&1 && break; sleep 0.5; done
  echo "==> pushing tesserix-k8s/charts to Gitea ($GITEA_ORG/$GITEA_REPO)"
  ( set -e; cd "$tmp"
    git init -q -b main
    git config user.email "sandbox@local"; git config user.name "sandboxctl"
    git add -A; git commit -q -m "charts snapshot" --allow-empty
    git remote add origin "http://${GITEA_ADMIN_USER}:${admin_pass}@127.0.0.1:13000/${GITEA_ORG}/${GITEA_REPO}.git"
    git push -q -f origin main )
  REPO_URL="$GITEA_IN_CLUSTER"
fi

# ── 2. Render the app-of-apps children + apply to Argo ───────────────────────
echo "==> applying app-of-apps (repoURL=$REPO_URL)"
helm template local-root "$HERE" \
  --set repoURL="$REPO_URL" \
  --set targetRevision="$REPO_REV" \
  "${HELM_ARGS[@]}" | kubectl apply -f -

echo
echo "==> done. Watch the waves: cnpg-operator -> local-infra -> products"
echo "    kubectl -n argocd get applications -l app.kubernetes.io/part-of=local-root"
