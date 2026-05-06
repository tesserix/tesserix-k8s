# Kargo Deployment Runbook (prod)

Kargo is the release / promotion control plane. It lives under the
`release` ArgoCD AppProject and is installed from the upstream Akuity
Helm chart at `oci://ghcr.io/akuity/kargo-charts/kargo`, pinned to
`1.9.8` in `argocd/prod/infrastructure/kargo.yaml`.

| Concern              | Where it lives                                                          |
|----------------------|-------------------------------------------------------------------------|
| AppProject           | `argocd/prod/projects/release.yaml`                                     |
| ArgoCD Application   | `argocd/prod/infrastructure/kargo.yaml`                                 |
| ExternalSecrets      | `external-secrets/prod/kargo/externalsecret.yaml`                       |
| Istio VirtualService | `charts/thirdparty/istio-config/templates/virtual-services.yaml` (`kargo-vs`) |
| Public hostname      | `kargo.tesserix.app` (covered by `*.tesserix.app` wildcard cert)        |
| Namespace            | `kargo`                                                                 |
| Helm chart version   | `1.9.8` (latest stable in 1.9.x)                                        |

## Auth model

- Built-in **Dex** + GitHub connector.
- `api.adminAccount.enabled: false` — local admin login is off; GitHub
  SSO is the only path in.
- `api.oidc.admins.claims.email` is the access gate; only these emails
  receive the Kargo `admin` role:
  - `samyak.rout@gmail.com`
  - `unidevidp@gmail.com`
- Anyone else with a GitHub account can complete OIDC, but Kargo's
  RBAC will not bind any role to them — the UI shows zero projects and
  the API rejects every mutating call. To make access *strictly*
  org-scoped on top of that, add an `orgs:` block to the Dex GitHub
  connector config in `kargo.yaml`.

## One-time setup (do this BEFORE merging)

### 1. Create the GitHub OAuth App

Settings → Developer settings → OAuth Apps → **New OAuth App**.

| Field                       | Value                                              |
|-----------------------------|----------------------------------------------------|
| Application name            | `Tesserix Kargo (prod)`                            |
| Homepage URL                | `https://kargo.tesserix.app`                       |
| Authorization callback URL  | `https://kargo.tesserix.app/dex/callback`          |

After creation:
- Click **Generate a new client secret**.
- Note the **Client ID** and the new **Client Secret**.
- Verify the OAuth App has read access to user emails (default
  `user:email` scope is requested by Dex automatically).

### 2. Populate GCP Secret Manager

```bash
PROJECT=tesseracthub-480811

# GitHub OAuth App credentials
gcloud secrets create prod-kargo-github-client-id     --project=$PROJECT --replication-policy=automatic
gcloud secrets create prod-kargo-github-client-secret --project=$PROJECT --replication-policy=automatic

echo -n "<CLIENT_ID>"     | gcloud secrets versions add prod-kargo-github-client-id     --project=$PROJECT --data-file=-
echo -n "<CLIENT_SECRET>" | gcloud secrets versions add prod-kargo-github-client-secret --project=$PROJECT --data-file=-

# Token signing key for the Kargo API. Even though the local admin
# login is disabled, the chart's api.secret reference still needs the
# keys to be present.
SIGNING_KEY=$(openssl rand -base64 48)
gcloud secrets create prod-kargo-admin-token-signing-key --project=$PROJECT --replication-policy=automatic
echo -n "$SIGNING_KEY" | gcloud secrets versions add prod-kargo-admin-token-signing-key --project=$PROJECT --data-file=-

# Placeholder password hash — never used because adminAccount.enabled
# is false. Generate any valid bcrypt hash so the Secret renders.
PLACEHOLDER_HASH=$(htpasswd -bnBC 10 "" "$(openssl rand -base64 24)" | tr -d ':\n')
gcloud secrets create prod-kargo-admin-password-hash --project=$PROJECT --replication-policy=automatic
echo -n "$PLACEHOLDER_HASH" | gcloud secrets versions add prod-kargo-admin-password-hash --project=$PROJECT --data-file=-
```

### 3. Configure Cloudflare Tunnel

In the Cloudflare Zero Trust dashboard:

- Networks → Tunnels → select the existing prod tunnel
  (`prod-cloudflare-tunnel-token`).
- Public Hostname → **Add**.
- Subdomain: `kargo`, Domain: `tesserix.app`.
- Service: `http://istio-ingressgateway.istio-ingress.svc.cluster.local:80`.
- TLS → No TLS Verify: enabled (the upstream is plain HTTP inside the
  mesh).

This matches the routing pattern used for `grafana.tesserix.app`,
`prometheus.tesserix.app`, etc.

### 4. Merge & let ArgoCD sync

Push the changes in this PR to `main`. Sync order driven by sync waves:

1. `release` AppProject (wave `-10`).
2. ExternalSecrets create `kargo-github-oauth` and `kargo-api-secret`
   in the `kargo` namespace once the namespace exists.
3. `kargo` Application (wave `2`) installs CRDs, controller, API, Dex,
   webhooks server, GC, management controller.
4. `istio-config` rolls out the `kargo-vs` VirtualService.

Verify:

```bash
export KUBECONFIG=~/.kube/gke-prod
kubectl -n kargo get pods
kubectl -n kargo get externalsecrets
kubectl -n kargo get vs kargo-vs
argocd app get kargo
```

Then visit `https://kargo.tesserix.app`, click **Sign in with GitHub**.
Sign in with one of the allowlisted GitHub accounts → you should land
on the Kargo UI as an admin. Sign in with a non-allowlisted account →
you reach the UI with zero projects and no actions.

## Day-2

### Adding / removing an admin email

Edit `argocd/prod/infrastructure/kargo.yaml`,
`api.oidc.admins.claims.email`, commit, push, let ArgoCD sync. No
restart required — Kargo re-reads the OIDC config on each request.

### Rotating the GitHub OAuth client secret

1. Generate a new client secret in the GitHub OAuth App.
2. `echo -n "<NEW_SECRET>" | gcloud secrets versions add prod-kargo-github-client-secret --project=tesseracthub-480811 --data-file=-`
3. Either wait up to 1h for ESO refresh, or
   `kubectl -n kargo delete secret kargo-github-oauth` to force an
   immediate re-sync, then `kubectl -n kargo rollout restart deploy kargo-api`.

### Bumping the Kargo version

Update `targetRevision` in `argocd/prod/infrastructure/kargo.yaml`.
Read the upstream changelog first — Kargo 2.x will introduce breaking
changes; staying on 1.9.x patch releases is safe.

## Existing `kargo-project` chart

The `charts/kargo/kargo-project/` chart and the `kargo/devtest/`
configuration predate this install. They define the *Project / Warehouse
/ Stage* resources for the legacy `tesseract-hub` platform. Once the
control plane lands they can be ported by:

- Pointing the corresponding `kargo-tesseract-hub-devtest` ArgoCD
  Application at the `release` project (currently it sits under
  `default`).
- Updating its destination namespace if you want it to land under the
  `kargo-*` convention managed by the new project.
