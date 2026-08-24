# Vertex AI Private Access — Build & Operate Runbook

**Status:** LIVE since 2026-06-12 · Terraform-managed (`terraform-new/stacks/12-vertex`)
**Scope:** private, keyless Vertex AI access from `tesseract-prod-in-gke` for DevAI and the
solo.io agentgateway, inside the existing VPC `tesseract-prod-in-vpc`.

---

## 1. Design (and why there is no new VPC)

A GKE cluster is bound to its VPC at creation and **cannot be re-homed**. The cluster's
network already had everything a private Vertex path needs (private nodes, Private Google
Access on the subnet, Cloud Router/NAT, `aiplatform.googleapis.com` enabled), so the Vertex
stack is built **inside** `tesseract-prod-in-vpc`:

```
DevAI / agentgateway pods (GKE, Workload Identity)
        │  ADC token for GSA (no API keys)
        ▼
aiplatform.googleapis.com  ── private DNS zone vertex-aiplatform ──► 10.255.0.2
        │                      (apex + wildcard A records)
        ▼
PSC forwarding rule `vertexapis` (all-apis bundle) ──► Vertex AI, in-VPC
```

- **DNS is scoped to `aiplatform.googleapis.com` only.** GCS/GCR/every other Google API keeps
  default resolution — zero blast radius. Widening to all of `googleapis.com` (for VPC-SC) is
  a deliberate later step.
- **Two callers are authorized** (`roles/aiplatform.user`):
  - `app-secrets-devai-prod@` — DevAI pods, direct-ADC transition path
  - `agentgateway-llm@` — the agentgateway's dedicated GSA (strategic path: all LLM traffic
    through the gateway; DevAI stays provider-independent)

### Address allocation

| Range | Use |
|---|---|
| 10.10.0.0/20 | subnet (nodes) |
| 10.20.0.0/16 | pods |
| 10.30.0.0/20 | services |
| 10.249.0.0/16 | servicenetworking peering (Cloud SQL etc.) |
| 172.16.0.0/28 | GKE master |
| **10.255.0.2** | **vertex-psc-ip (this stack)** |

---

## 2. What was executed (manual gcloud, 2026-06-12)

All subsequently codified in Terraform and imported — listed here for the audit trail and
for rebuilding in another project/environment:

```bash
PROJECT=tesseracthub-480811
VPC=tesseract-prod-in-vpc

# 2.1 PSC endpoint for Google APIs
gcloud compute addresses create vertex-psc-ip --global \
  --purpose=PRIVATE_SERVICE_CONNECT --addresses=10.255.0.2 \
  --network=projects/$PROJECT/global/networks/$VPC --project=$PROJECT

gcloud compute forwarding-rules create vertexapis --global \
  --network=$VPC --address=vertex-psc-ip \
  --target-google-apis-bundle=all-apis --project=$PROJECT
  # NB: PSC rule names — lowercase letters/digits only, max 20 chars

# 2.2 Private DNS, scoped to Vertex
gcloud dns managed-zones create vertex-aiplatform \
  --dns-name="aiplatform.googleapis.com." --visibility=private \
  --networks=$VPC --project=$PROJECT \
  --description="Pin Vertex AI traffic to the vertexapis PSC endpoint (10.255.0.2)"

gcloud dns record-sets create "aiplatform.googleapis.com."   --zone=vertex-aiplatform --type=A --ttl=300 --rrdatas=10.255.0.2 --project=$PROJECT
gcloud dns record-sets create "*.aiplatform.googleapis.com." --zone=vertex-aiplatform --type=A --ttl=300 --rrdatas=10.255.0.2 --project=$PROJECT

# 2.3 IAM — Vertex callers
gcloud projects add-iam-policy-binding $PROJECT --condition=None \
  --member="serviceAccount:app-secrets-devai-prod@$PROJECT.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user"

gcloud iam service-accounts create agentgateway-llm \
  --display-name="Agentgateway LLM egress (Vertex AI)" --project=$PROJECT
gcloud projects add-iam-policy-binding $PROJECT --condition=None \
  --member="serviceAccount:agentgateway-llm@$PROJECT.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user"

# 2.4 Workload Identity: gateway KSA → GSA
gcloud iam service-accounts add-iam-policy-binding \
  agentgateway-llm@$PROJECT.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:$PROJECT.svc.id.goog[agentgateway-system/agentgateway]" \
  --project=$PROJECT
```

The K8s half of 2.4 is the KSA annotation in
`charts/thirdparty/agentgateway/values.yaml` (`iam.gke.io/gcp-service-account:
agentgateway-llm@…`) — deployed by ArgoCD, never `kubectl apply`.

---

## 3. Terraform (source of truth going forward)

Stack: **`terraform-new/stacks/12-vertex`** — PSC address + forwarding rule, DNS zone +
records, gateway GSA, both `aiplatform.user` grants, the WI binding. Registered in the
Makefile (`*-12-vertex` targets) and `environments/prod/terraform.tfvars`.

```bash
cd terraform-new
make plan-12-vertex     # must show: No changes.
make apply-12-vertex    # idempotent
```

### State import (already done — repeat only when rebuilding elsewhere)

State lives at `gs://tesseract-terraform-states/stacks/prod/vertex`. After any manual
bootstrap, reconcile with:

```bash
cd terraform-new/stacks/12-vertex
terraform init -backend-config="bucket=tesseract-terraform-states" \
               -backend-config="prefix=stacks/prod/vertex" -reconfigure

V=(-var-file=../../environments/prod/terraform.tfvars \
   -var=project_id=tesseracthub-480811 -var=environment=prod \
   -var=state_bucket=tesseract-terraform-states -compact-warnings)

terraform import "${V[@]}" google_compute_global_address.vertex_psc_ip            projects/tesseracthub-480811/global/addresses/vertex-psc-ip
terraform import "${V[@]}" google_compute_global_forwarding_rule.vertex_psc       projects/tesseracthub-480811/global/forwardingRules/vertexapis
terraform import "${V[@]}" google_dns_managed_zone.vertex_aiplatform              projects/tesseracthub-480811/managedZones/vertex-aiplatform
terraform import "${V[@]}" google_dns_record_set.vertex_apex                      "projects/tesseracthub-480811/managedZones/vertex-aiplatform/rrsets/aiplatform.googleapis.com./A"
terraform import "${V[@]}" google_dns_record_set.vertex_wildcard                  "projects/tesseracthub-480811/managedZones/vertex-aiplatform/rrsets/*.aiplatform.googleapis.com./A"
terraform import "${V[@]}" google_service_account.agentgateway_llm                projects/tesseracthub-480811/serviceAccounts/agentgateway-llm@tesseracthub-480811.iam.gserviceaccount.com
terraform import "${V[@]}" google_project_iam_member.agentgateway_llm_aiplatform  "tesseracthub-480811 roles/aiplatform.user serviceAccount:agentgateway-llm@tesseracthub-480811.iam.gserviceaccount.com"
terraform import "${V[@]}" google_project_iam_member.devai_workload_aiplatform    "tesseracthub-480811 roles/aiplatform.user serviceAccount:app-secrets-devai-prod@tesseracthub-480811.iam.gserviceaccount.com"
terraform import "${V[@]}" google_service_account_iam_member.agentgateway_wi      "projects/tesseracthub-480811/serviceAccounts/agentgateway-llm@tesseracthub-480811.iam.gserviceaccount.com roles/iam.workloadIdentityUser serviceAccount:tesseracthub-480811.svc.id.goog[agentgateway-system/agentgateway]"

terraform plan "${V[@]}"   # acceptance gate: "No changes."
```

Known drift note: the `app-secrets-devai-prod@` **service account itself** is not
Terraform-managed (pre-dates this stack); `12-vertex` references it by email only.

---

## 4. Verify

```bash
# Resources exist and agree
gcloud compute addresses describe vertex-psc-ip --global --project=$PROJECT --format="value(address,status)"   # 10.255.0.2 RESERVED
gcloud compute forwarding-rules describe vertexapis --global --project=$PROJECT --format="value(IPAddress,target)"  # 10.255.0.2 all-apis
gcloud dns record-sets list --zone=vertex-aiplatform --project=$PROJECT

# IAM
gcloud projects get-iam-policy $PROJECT \
  --flatten="bindings[].members" --filter="bindings.role:roles/aiplatform.user" \
  --format="value(bindings.members)"

# From inside the cluster (read-only): DNS must resolve to the PSC IP
kubectl run dnscheck --rm -it --image=busybox --restart=Never -- \
  nslookup asia-south1-aiplatform.googleapis.com    # expect 10.255.0.2

# Terraform is the source of truth
cd terraform-new && make plan-12-vertex             # expect: No changes.
```

---

## 5. Consume

| Caller | How |
|---|---|
| **devai-api / devai-sre pods** | `vertex_gemini` LLM adapter (REST + ADC, shipped in devai) — KSA `devai/devai-api` → WI → `app-secrets-devai-prod@`. Env: `DEVAI_VERTEX_PROJECT/LOCATION/GEMINI_MODEL` from `charts/apps/devai-api` (`llm.vertexEnabled` in values-prod). Selectable globally (`DEVAI_LLM_PROVIDER=vertex_gemini`) or per specialization. |
| **ADK runner Jobs** (agents as K8s Jobs) | KSA `devai/devai-runner` → WI → same GSA (binding owned by `12-vertex` Terraform). Dispatched agents inherit the vertex env and mint ADC in-Job. |
| **DevAI `ai-gateway` (AgentGateway)** | `/vertex/*` routes to `aiplatform.googleapis.com` through KSA `agentgateway-system/ai-gateway` → GSA `agentgateway-llm@` Workload Identity. `prod-devai-vertex-api-key` remains synced by ESO as a rollback credential, but Solo v1.4.1's key-backed xDS path returned 503 even though the same key returned 200 directly; the active backend therefore uses the proven ADC path. devai-api carries neither credential. |
| **Cost tiers** | `DEVAI_LLM_TIER_{LIGHT,STANDARD,HEAVY,FRONTIER}` = `provider:model`, resolved by `resolve_llm_tier()` in devai. Today: light/standard → `vertex_gemini:gemini-2.5-flash`, heavy → `anthropic:claude-sonnet-4-20250514`, frontier → `openai:o3` (all via the gateway). ⚠️ Only `gemini-2.5-flash` is model-enabled in the project — every other Gemini ID (2.5-pro, flash-lite, 3.x) returns 404 until enabled in console (Agent Platform → Models); then flip the tier values in `devai-api/values-prod.yaml`. |
| **agentgateway** (strategic) | pods run as KSA `agentgateway-system/agentgateway` → WI → `agentgateway-llm@` → ADC. Gateway config maps model aliases → Vertex/Anthropic/OpenAI backends. ⚠️ chart wrapper is `replicaCount: 0` until the upstream Helm chart (`oci://ghcr.io/agentgateway/agentgateway/charts/agentgateway`) is adopted with backend routes. |
| **MCP** | Google's system MCP servers are registered as DevAI registry seeds (`google-vertex-mcp` → `https://aiplatform.googleapis.com/mcp/generate`: generate_content/count_tokens/embed_content; `google-agent-registry-mcp` → `https://agentregistry.googleapis.com/mcp`: 20 discovery tools). DevAI's MCP Hub injects ADC bearers via the new `authMode: gcp_adc`. |

**Validated 2026-06-12:** `generateContent` returns 200 as `agentgateway-llm@` (impersonated)
against both `global` and `asia-south1`; both Google MCP endpoints answer `tools/list`.
**In-cluster proof (same day):** from the devai-api pod, the pod's Workload Identity token
against `aiplatform.googleapis.com` → resolved to 10.255.0.2 (PSC) → HTTP 200. This —
keyless ADC, direct from the pod — is the production path.

**Known issue — gateway /vertex parked:** pod egress in `agentgateway-system` (istio
ambient + waypoint) re-frames POST bodies as chunked; Google's PSC frontend rejects
chunked POSTs with **411 Length Required**. Anthropic/OpenAI tolerate chunked, so those
gateway routes work; Vertex via the gateway does not until the namespace's L7 egress
handling is fixed (likely with the upstream agentgateway chart adoption). The /vertex
route, ExternalSecret key injection, and `istio.io/use-waypoint: none` opt-out are all in
place and tested up to that hop. Required NetworkPolicy fix (committed): the hand-applied
`allow-agentgateway-egress` excluded all of 10.0.0.0/8 on 443, silently blocking the PSC
IP — adopted into git with a leading allow for 10.255.0.2/32.
**Gotcha:** impersonated/user ADC tokens MUST send `x-goog-user-project` (otherwise Vertex
404s); GKE Workload Identity metadata tokens don't need it. DevAI's adapter and MCP hub
always send it.

Still pending (deliberate): Claude Model Garden terms acceptance (console, once), per-model
quotas + Vertex budget alert, VPC Service Controls perimeter (requires widening DNS to all of
`googleapis.com` — plan that change; it re-routes every Google API in the VPC).

---

## 6. Access control — who can reach Vertex from where (verified 2026-06-12)

`aiplatform.googleapis.com` is Google's shared public frontend — it cannot be taken off
the internet. What is controlled is **whose credentials work, and from where**:

| Credential | From GKE/VPC | From outside (Mac/internet) | Why |
|---|---|---|---|
| Workload Identity (devai pods, runner Jobs, gateway) | ✅ works | ❌ impossible | WI tokens are mintable only by bound KSAs inside the cluster; **zero user-managed keys exist** on either GSA (verified) |
| `prod-devai-vertex-api-key` | ✅ (VPC source ranges) | ❌ **403 verified** | API key now carries an IP restriction (10.20/16, 10.10/20, 10.30/20) + API restriction (aiplatform only) |
| Human owner accounts (gmail) | ✅ | ⚠️ still works | Cannot be network-restricted without **VPC Service Controls** |

**The full "VPC-only even with valid credentials" guarantee requires VPC Service
Controls, which requires a GCP Organization — this account has none** (standalone
project). Path when wanted: Cloud Identity Free on a owned domain (e.g. tesserix.app)
→ creates the Organization → migrate `tesseracthub-480811` into it
(`gcloud beta projects move`) → Access Context Manager policy → perimeter around
`aiplatform.googleapis.com` (+ Secret Manager) in **dry-run** first, with an access
level for admin identities (else the console from the Mac is locked out too) → enforce.

## 7. Rollback

Reverse order; DNS first restores default (public-VIP) resolution instantly:

```bash
gcloud dns record-sets delete "*.aiplatform.googleapis.com." --zone=vertex-aiplatform --type=A --project=$PROJECT
gcloud dns record-sets delete "aiplatform.googleapis.com."   --zone=vertex-aiplatform --type=A --project=$PROJECT
gcloud dns managed-zones delete vertex-aiplatform --project=$PROJECT
gcloud compute forwarding-rules delete vertexapis --global --project=$PROJECT
gcloud compute addresses delete vertex-psc-ip --global --project=$PROJECT
# (IAM grants can stay; they are harmless without the endpoint)
```

or `make destroy-12-vertex` (same effect, plus IAM/GSA removal — note this deletes the
`agentgateway-llm` GSA). Pods fall back to Private Google Access routing either way, so
Vertex keeps working — rollback removes the pinned endpoint, not connectivity.
