# Evals onboarding operator

Claims in `claims/` give each graded product a Langfuse project, a project API
key pair mirrored to Secret Manager as `prod-<claim>-langfuse-{public,secret}-key`,
and `eval.datasets` rows on `evals_db` (australis ADR-0003). Source:
`tesserix-operators/operators/evals`.

## One-time prerequisites

1. Organization-scoped Langfuse key: Langfuse UI -> Organization Settings ->
   API Keys -> create, then store both halves:

   ```bash
   gcloud secrets create prod-evals-langfuse-org-public-key --project=tesseracthub-480811 \
     --replication-policy=user-managed --locations=asia-south1 \
     --data-file=/secure/path/langfuse-public-secret
   gcloud secrets create prod-evals-langfuse-org-secret-key --project=tesseracthub-480811 \
     --replication-policy=user-managed --locations=asia-south1 \
     --data-file=/secure/path/langfuse-secret
   ```

2. GCP identity (mirrors `analytics-onboarding-operator`):

   ```bash
   P=tesseracthub-480811; N=849928263410; SA=evals-onboarding-operator@$P.iam.gserviceaccount.com
   gcloud iam service-accounts create evals-onboarding-operator --project=$P --display-name="Evals onboarding operator"
   gcloud iam roles create evalsOnboardingSecretCreator --project=$P --title="Evals onboarding secret creator" --permissions=secretmanager.secrets.create --stage=GA
   gcloud iam roles create evalsOnboardingSecretManager --project=$P --title="Evals onboarding secret manager" --permissions=secretmanager.secrets.get,secretmanager.versions.access,secretmanager.versions.add --stage=GA
   gcloud projects add-iam-policy-binding $P --member=serviceAccount:$SA --role=projects/$P/roles/evalsOnboardingSecretCreator --condition=None
   gcloud projects add-iam-policy-binding $P --member=serviceAccount:$SA --role=projects/$P/roles/evalsOnboardingSecretManager \
     --condition="expression=resource.name.startsWith('projects/$N/secrets/prod-') && (resource.name.endsWith('-langfuse-public-key') || resource.name.endsWith('-langfuse-secret-key') || resource.name.extract('/secrets/{s}/versions/').endsWith('-langfuse-public-key') || resource.name.extract('/secrets/{s}/versions/').endsWith('-langfuse-secret-key')),title=evals-langfuse-keys-only"
   gcloud iam service-accounts add-iam-policy-binding $SA --project=$P --role=roles/iam.workloadIdentityUser \
     --member="serviceAccount:$P.svc.id.goog[evals-operator/evals-onboarding-operator]"
   ```

## Adding a product

Add `claims/<product>.yaml`, list it in `claims/kustomization.yaml`, merge.
The product namespace then consumes the keys through an ExternalSecret pointing
at `prod-<product>-langfuse-public-key` / `-secret-key`.

## Verification

```bash
kubectl get evalonboardings -n evals-operator
kubectl describe evalonboarding <product> -n evals-operator
```
