# Break-glass: reaching secrets without the console

**Use this when the console is unavailable** — Zitadel is down, the console will
not deploy, or you cannot sign in — and you need to read or rotate a secret.

**Every step below was executed against production on 2026-09-03**, including
the escalation in step 4, whose artefacts were removed afterwards. Exact
responses are recorded so the next person can tell "this is broken" apart from
"I did it wrong".

Steps 1-3 and 6 are re-checked daily; step 4 is not, because it writes.

---

## Do not start here: the credential that looks right is revoked

The independently encrypted GCS recovery record contains an archived `root_token` field.
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

**If you are reading this during an incident: skip to step 1. The archived root token is not your way in.**

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

## 4. If you must read or write a secret value

The bootstrap policy grants `sys/policies/acl/*` and `auth/kubernetes/role/*`,
so it can grant itself access. That is root-equivalent by escalation and is the
only route to a secret value without the console.

**Executed against production on 2026-09-03**, then removed. What was observed:

```
POST auth/kubernetes/login (role=break-glass-probe)
  -> policies: ["break-glass-probe","default"], ttl 600s
GET  kv/data/cloudflared/cloudflared/tunnel
  -> 200, key names ["token"], version 1
GET  kv/data/homechef/homechef-api/db          <- a namespace NOT in the policy
  -> 403 permission denied
```

That last line is the one worth having: **the narrow scope actually binds.** A
policy written against `kv/data/*` would have read both, and nothing in the
happy path would have told you.

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

## This runbook is checked daily

`.github/workflows/openbao-break-glass-check.yml` runs `scripts/check_break_glass.py`
every day. It performs steps 1-3 and 6 against production — logs in as the
bootstrap identity, asserts the policies it receives, asserts it **cannot** read
a secret value, and revokes — then confirms the recovery secret still holds five
shares.

If that job is red, this document is wrong and the next incident will find out
the hard way. It exists because the credential described at the top of this page
was revoked and dead for weeks with nothing noticing.

It deliberately does **not** cover step 4, which writes.

## Known weaknesses in this procedure

Recorded rather than hidden, because a runbook that hides its own gaps is worse
than none.

- **Nothing here is exercised automatically except steps 1-3 and 6.** The daily
  check deliberately does not perform step 4, because it writes. Step 4 was
  verified by hand once, on 2026-09-03; if the policy grants change it could
  rot without anything noticing.
- **All five recovery shares remain in one encrypted recovery record.** IAM
  and KMS access to that record, rather than the 3-of-5 threshold alone, form
  the authorization boundary. Routine backup/restore-test identities must not
  read this bootstrap material.
- The archived initial root token is deliberately revoked. The daily checker
  now requires its lookup to return HTTP 403; it is not an emergency credential.

## Independent recovery material

The canonical object is
`gs://tesseracthub-480811-openbao-bootstrap-prod/bootstrap/init.json.kms`,
client-encrypted with `openbao-bootstrap-key` and stored with bucket CMEK. It
can be retrieved using an authorized GCP identity without Kubernetes, ESO,
Argo CD or a functioning OpenBao. KMS auto-unseal remains a separate dependency.
Do not print recovery material or put it in shell arguments.

```bash
umask 077
export RECOVERY_OBJECT_URI=gs://tesseracthub-480811-openbao-bootstrap-prod/bootstrap/init.json.kms
export RECOVERY_KMS_KEY=projects/tesseracthub-480811/locations/asia-south1/keyRings/tesseract-prod-in-keyring/cryptoKeys/openbao-bootstrap-key
python3 charts/thirdparty/openbao/files/recovery_record.py load /secure/private/recovery.json
```

Use a private operator-controlled directory for the output; remove the plaintext
file once the recovery procedure is complete. Do not use the old Secret Manager
record as the steady-state reader after cutover. Retain it until acceptance and
the separate source-retirement change are complete.

Bootstrap defaults to `allowInitialization: false`. A restored cluster must
restore its existing Raft state, not initialize new keys. Fresh initialization
requires explicit opt-in and an absent canonical recovery object. A retained
`openbao-bootstrap-staging` PVC holds any pending init response until encrypted
upload and byte verification succeed. Retries persist the same pending record;
a filesystem lock prevents concurrent bootstrap jobs. Never delete that PVC to
work around a failed upload. Do not apply snapshot retention to this bucket.
