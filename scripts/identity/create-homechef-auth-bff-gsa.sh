#!/usr/bin/env bash
# create-homechef-auth-bff-gsa.sh
#
# Provisions the Google Service Account that the homechef-auth-bff
# pod impersonates via Workload Identity. Run once per cluster — the
# resulting bindings are persistent and survive pod restarts.
#
# Why not Terraform: mark8ly-auth-bff's GSA is also script-managed
# (no `mark8ly_auth_bff` entry in terraform-new/environments/prod/
# terraform.tfvars). Mirroring that pattern keeps both auth-bffs on
# the same lifecycle. Migrate to Terraform when the team consolidates
# the per-service GSAs into a single managed list.
#
# Idempotent — re-running is safe (errors from "already exists" are
# absorbed by the `|| true` on the create step; binding adds are
# inherently idempotent).
#
# Usage: ./scripts/identity/create-homechef-auth-bff-gsa.sh

set -euo pipefail

PROJECT=tesseracthub-480811
GSA_NAME=homechef-auth-bff
GSA_EMAIL="${GSA_NAME}@${PROJECT}.iam.gserviceaccount.com"
K8S_NAMESPACE=homechef
K8S_SA=homechef-auth-bff

echo "==> Creating GSA ${GSA_EMAIL}"
gcloud iam service-accounts create "${GSA_NAME}" \
  --project="${PROJECT}" \
  --display-name="Home Chef auth-bff" \
  --description="Workload Identity for the homechef-auth-bff pods" \
  || echo "    GSA already exists — continuing"

echo "==> Granting project-level GIP/Firebase viewer roles"
for role in roles/identitytoolkit.viewer roles/firebaseauth.viewer; do
  echo "    + ${role}"
  gcloud projects add-iam-policy-binding "${PROJECT}" \
    --member="serviceAccount:${GSA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    > /dev/null
done

echo "==> Binding KSA ${K8S_NAMESPACE}/${K8S_SA} → GSA ${GSA_EMAIL}"
gcloud iam service-accounts add-iam-policy-binding "${GSA_EMAIL}" \
  --project="${PROJECT}" \
  --member="serviceAccount:${PROJECT}.svc.id.goog[${K8S_NAMESPACE}/${K8S_SA}]" \
  --role="roles/iam.workloadIdentityUser" \
  > /dev/null

echo "==> Done. Verify with:"
echo "    gcloud iam service-accounts get-iam-policy ${GSA_EMAIL} --project ${PROJECT}"
