#!/usr/bin/env bash
# gip-local-setup.sh — make Google Identity Platform (GIP) usable from the
# local sandbox (*.sandbox.app), without disturbing the prod tenant pools.
#
# It does two things against your GCP project:
#   1. Adds `sandbox.app` to the GIP Authorized domains (so the sign-in
#      redirect from https://devai.sandbox.app:8443 is allowed).
#   2. Creates two DEDICATED local tenants (devai-local-alm / devai-local-sre)
#      so local logins are isolated from the prod ALM/SRE tenant pools.
#
# Then it prints the tenant IDs + web API key to paste into devai/k8s/secrets.yaml
# (DEVAI_BFF_ALM_TENANT_ID / DEVAI_BFF_SRE_TENANT_ID / DEVAI_BFF_GIP_WEB_API_KEY).
#
# Run it yourself — it mutates your GCP project (outward action):
#   gcloud auth login        # interactive (use `! gcloud auth login` in the agent)
#   PROJECT=tesseracthub-480811 tesserix-k8s/local/gip-local-setup.sh
#
# Prefer total isolation? Point PROJECT at a SEPARATE GCP project dedicated to
# local testing and run this there — nothing else changes.
set -euo pipefail

PROJECT="${PROJECT:-tesseracthub-480811}"
DOMAIN="${DOMAIN:-sandbox.app}"
API="https://identitytoolkit.googleapis.com/admin/v2/projects/${PROJECT}"
TOKEN="$(gcloud auth print-access-token)"
hdr=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -H "X-Goog-User-Project: ${PROJECT}")

say() { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }

# ── 1. Authorized domains (merge sandbox.app into the existing list) ──
say "Adding ${DOMAIN} to GIP authorized domains on ${PROJECT}"
current="$(curl -s "${hdr[@]}" "${API}/config")"
domains="$(printf '%s' "$current" | python3 -c '
import sys, json
cfg = json.load(sys.stdin)
ds = set(cfg.get("authorizedDomains", []) or ["localhost"])
import os
ds.add(os.environ["DOMAIN"])
print(json.dumps(sorted(ds)))
')"
curl -s "${hdr[@]}" -X PATCH \
  "${API}/config?updateMask=authorizedDomains" \
  -d "{\"authorizedDomains\": ${domains}}" >/dev/null
echo "   authorized domains now: ${domains}"

# ── 2. Local tenants (idempotent by displayName) ──
ensure_tenant() {  # ensure_tenant <displayName>
  local dn="$1" existing
  existing="$(gcloud identity-platform tenants list --project="$PROJECT" \
                --format="value(name)" --filter="displayName=$dn" 2>/dev/null | head -n1 || true)"
  if [[ -n "$existing" ]]; then
    echo "${existing##*/}"          # tenant id
  else
    gcloud identity-platform tenants create "$dn" --project="$PROJECT" \
      --allow-password-signup --format="value(name)" 2>/dev/null | sed 's#.*/##'
  fi
}

say "Ensuring local tenants"
ALM_ID="$(ensure_tenant devai-local-alm)"
SRE_ID="$(ensure_tenant devai-local-sre)"

WEB_KEY="$(gcloud services api-keys list --project="$PROJECT" \
  --filter="displayName~'Browser key' OR displayName~'Web'" \
  --format="value(keyString)" 2>/dev/null | head -n1 || true)"

cat <<EOF

✅ GIP local setup complete. Put these in devai/k8s/secrets.yaml
   (Secret: devai-auth-bff-secrets):

   DEVAI_BFF_ALM_TENANT_ID: "${ALM_ID}"
   DEVAI_BFF_SRE_TENANT_ID: "${SRE_ID}"
   DEVAI_BFF_GIP_WEB_API_KEY: "${WEB_KEY:-<find in GCP Console → APIs & Services → Credentials>}"

   And confirm in devai-auth-bff/values-local.yaml:
   DEVAI_BFF_GCP_PROJECT_ID: "${PROJECT}"
   DEVAI_BFF_GIP_AUTH_DOMAIN: "${PROJECT}.firebaseapp.com"

Create a local test user in each tenant (Console → Identity Platform → Users,
pick the tenant), then log in at https://devai.sandbox.app:8443.
EOF
