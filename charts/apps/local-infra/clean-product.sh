#!/usr/bin/env bash
# Reset ONE product's data in the shared local infra so you can switch to
# another product cleanly. Triggers that product's suspended cleanup CronJob,
# which drops+recreates its Postgres DB(s), flushes its Redis logical DB, drops
# its Mongo DB (if any), and removes its NATS streams (if any). Other products
# are untouched.
#
#   ./clean-product.sh <product>     # one of: agentic-registry devai homechef mark8ly fanzone
#   ./clean-product.sh --list        # show configured products + their slices
set -euo pipefail

# DEFAULT ALWAYS to the local sandbox kubeconfig (ignore ambient $KUBECONFIG,
# which may point at prod). Override via SANDBOX_KUBECONFIG.
export KUBECONFIG="${SANDBOX_KUBECONFIG:-$HOME/.sandboxctl/kubeconfig}"
[[ -f "$KUBECONFIG" ]] || { echo "✗ sandbox kubeconfig not found: $KUBECONFIG (run 'sandboxctl up')"; exit 1; }

# SAFETY: LOCAL-ONLY — refuse to mutate anything that isn't a kind/sandbox cluster.
ctx="$(kubectl config current-context 2>/dev/null || true)"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
if [[ "$ctx" != kind-* && "$ctx" != *sandbox* && "$server" != *127.0.0.1* && "$server" != *localhost* ]]; then
  echo "✗ REFUSING — '$ctx' ($server) is not a local kind/sandbox cluster. This tool is LOCAL-ONLY."
  [[ "${ALLOW_NONLOCAL:-}" == "1" ]] || exit 1
fi

NS="${LOCAL_INFRA_NS:-local-infra}"
PRODUCT="${1:-}"

if [[ "$PRODUCT" == "--list" || -z "$PRODUCT" ]]; then
  echo "Products with a cleanup job in namespace $NS:"
  kubectl -n "$NS" get cronjob -l app.kubernetes.io/part-of=local-infra \
    -o custom-columns=NAME:.metadata.name,PRODUCT:'.metadata.annotations.local-infra/product' 2>/dev/null \
    | sed 's/^/  /'
  [[ -z "$PRODUCT" ]] && { echo; echo "usage: $0 <product>"; exit 2; }
  exit 0
fi

CJ="local-infra-clean-${PRODUCT}"
if ! kubectl -n "$NS" get cronjob "$CJ" >/dev/null 2>&1; then
  echo "!! no cleanup job '$CJ' in namespace $NS"
  echo "   known products:"; "$0" --list
  exit 1
fi

JOB="${CJ}-$(date +%s)"
echo "==> resetting '$PRODUCT' data (job $JOB)"
kubectl -n "$NS" create job --from="cronjob/$CJ" "$JOB"
kubectl -n "$NS" wait --for=condition=complete --timeout=180s "job/$JOB" || true
echo "---- logs ----"
kubectl -n "$NS" logs "job/$JOB" --all-containers=true || true
echo "==> done. '$PRODUCT' is reset; other products untouched."
