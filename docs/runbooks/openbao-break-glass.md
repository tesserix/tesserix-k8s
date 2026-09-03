# Break-glass: reaching secrets without the console

**Use this when the console is unavailable** — Zitadel is down, the console will
not deploy, or you cannot sign in — and you need to read or rotate a secret.

Everything below was executed against production on 2026-09-03, except the one
step marked UNVERIFIED. Timings and exact responses are recorded so the next
person can tell "this is broken" apart from "I did it wrong".

---

## Do not start here: the credential that looks right is revoked

`prod-openbao-recovery-keys` in Secret Manager contains a `root_token` field.
**It does not work.**

```
GET /v1/sys/mounts              -> {"errors":["permission denied"]}
GET /v1/auth/token/lookup-self  -> {"errors":["permission denied"]}
```

This is deliberate, not corruption: the bootstrap Job revokes the initial root
token at the end of every run (`auth/token/revoke-self` in
`charts/thirdparty/openbao/templates/bootstrap-configmap.yaml`). A long-lived
root token should not exist. The stored copy was simply never cleared.

Root regeneration is also unavailable on this cluster:

```
PUT /v1/sys/generate-root/attempt            -> {"errors":["unsupported operation"]}
PUT /v1/sys/generate-recovery-token/attempt  -> {"errors":["permission denied"]}
```

The seal is `gcpckms` with `recovery_seal: true` (threshold 3 of 5), and
recovery shares cannot be presented as a token.

**If you are reading this during an incident: skip to step 1. The recovery-keys
secret is not your way in.**

---

## What you need

- `kubectl` against `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`,
  with permission to create a service-account token in the `openbao` namespace
- `gcloud` against `tesseracthub-480811`, only if the secret you want lives in
  Secret Manager rather than OpenBao (612 of 623 do — see step 5)

No console session, no Zitadel, no GitHub.

---

## 1. Reach OpenBao

It is `ClusterIP` only; there is no ingress.

```bash
kubectl -n openbao port-forward svc/openbao-active 8200:8200
export BAO_ADDR=http://127.0.0.1:8200
```

Confirm it is up and unsealed before going further:

```bash
curl -s $BAO_ADDR/v1/sys/health | jq '{initialized, sealed, standby}'
# {"initialized": true, "sealed": false, "standby": false}
```

`sealed: true` is a different incident — this runbook does not cover unsealing.

## 2. Authenticate as the bootstrap identity

The Kubernetes auth method is the way in. The `openbao-bootstrap` service
account maps to the `bootstrap` role.

```bash
SA_TOKEN=$(kubectl -n openbao create token openbao-bootstrap --duration=10m)

BAO_TOKEN=$(curl -s -X POST "$BAO_ADDR/v1/auth/kubernetes/login" \
  -H 'Content-Type: application/json' \
  -d "{\"role\":\"bootstrap\",\"jwt\":\"$SA_TOKEN\"}" \
  | jq -r .auth.client_token)
```

Verified response: `policies: ["bootstrap","default"]`, `lease_duration: 600`.

**Ten minutes.** Long enough to work, short enough that forgetting to revoke is
not a standing risk. Re-run this step if it expires.

## 3. Know what this token can and cannot do

Verified directly:

| action | result |
|---|---|
| `GET sys/mounts` | allowed |
| `GET sys/policies/acl/bootstrap` | allowed |
| **read a secret value** (`kv/data/...`) | **permission denied** |

This is the point of the design, not a fault. The bootstrap identity administers
OpenBao; it does not read from it. If you only need to confirm OpenBao is
healthy or inspect its configuration, stop here — you already have what you
need, and you have read nothing.

## 4. If you must read or write a secret value — UNVERIFIED

The bootstrap policy grants `sys/policies/acl/*` and `auth/kubernetes/role/*`,
so it can grant itself access. That is root-equivalent by escalation and is the
only route to a secret value without the console.

**This step has not been executed in production.** Steps 1–3 and 6 have. It is
written from the policy, and proving it is the first job of the next drill
(tesserix-home#462) — do not assume it is correct because it is written down.

```bash
# a) create a narrowly scoped read policy
curl -s -X PUT "$BAO_ADDR/v1/sys/policies/acl/break-glass" \
  -H "X-Vault-Token: $BAO_TOKEN" \
  -d '{"policy":"path \"kv/data/<namespace>/*\" { capabilities = [\"read\"] }\npath \"kv/metadata/<namespace>/*\" { capabilities = [\"read\",\"list\"] }"}'

# b) bind it to a service account you control
curl -s -X POST "$BAO_ADDR/v1/auth/kubernetes/role/break-glass" \
  -H "X-Vault-Token: $BAO_TOKEN" \
  -d '{"bound_service_account_names":"<sa>","bound_service_account_namespaces":"<ns>","policies":"break-glass","ttl":"10m"}'

# c) log in again with that service account's token, then read
```

**Scope it to the one namespace you need.** `kv/data/*` makes the whole
authorization model decorative — the same rule the chart states for every other
policy.

**Remove both when finished:**

```bash
curl -s -X DELETE "$BAO_ADDR/v1/sys/policies/acl/break-glass"      -H "X-Vault-Token: $BAO_TOKEN"
curl -s -X DELETE "$BAO_ADDR/v1/auth/kubernetes/role/break-glass"  -H "X-Vault-Token: $BAO_TOKEN"
```

They are not in `values.yaml`, so the next bootstrap sync will not remove them
for you — and a forgotten break-glass role is a standing grant nobody reviews.

## 5. Most secrets are not in OpenBao

The inventory is **612 in Google Secret Manager, 11 in OpenBao**. If what you
need is one of the 612 — including **every credential Zitadel itself uses**
(`zitadel-masterkey`, `zitadel-login-service-key`, `zitadel-admin-password`,
`zitadel-db-credentials`, and the console's `ZITADEL_*` values) — none of the
above applies:

```bash
gcloud secrets versions access latest --secret <name> --project tesseracthub-480811
```

That matters for the case people worry about: **recovering Zitadel does not
require OpenBao or the console.** A GCP credential is sufficient.

## 6. Revoke when you are done

```bash
curl -s -X POST "$BAO_ADDR/v1/auth/token/revoke-self" -H "X-Vault-Token: $BAO_TOKEN"
```

Verified: `lookup-self` afterwards returns `permission denied`. The Kubernetes
token expires on its own in 10 minutes; the OpenBao token does not always, so
revoke it explicitly.

---

## Known weaknesses in this procedure

Recorded rather than hidden, because a runbook that hides its own gaps is worse
than none.

- **Step 4 is unverified.** See above.
- **All five recovery shares live in one Secret Manager entry**
  (`prod-openbao-recovery-keys`). A 3-of-5 split exists so no single party holds
  enough to recover; whoever can read that secret holds all five. The split is
  arithmetic, not a control, as currently stored.
- **The stale `root_token` is a trap** and remains one until that field is
  removed. It is the first thing an operator will try and it fails with a bare
  `permission denied`.
- **Nothing detects any of this.** No check compares the stored credential
  against what OpenBao accepts, which is why a revoked token sat there
  unnoticed until someone tried to use it.
