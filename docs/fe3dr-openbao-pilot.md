# fe3dr OpenBao exchange-rate pilot

Tracks [#1159](https://github.com/tesserix/tesserix-k8s/issues/1159).
Status: source version 1 copied and verified as OpenBao version 1 on 2026-09-27.
The existing app read role and Kubernetes target were verified byte-for-byte.
Temporary writer grants/tokens were removed. Production cutover remains pending
the recovery gates; the proposed production values enable it when deployed.

## Naming and ownership

Every migrated secret identifier starts with `fe3dr-<secret-name>`.
The identifier is the final path component; existing namespace/application
prefixes remain the authorization boundary. For example:

| GCP source | OpenBao CLI path | JSON field |
|---|---|---|
| `prod-homechef-openexchangerates-app-id` | `kv/homechef/homechef-api/fe3dr-openexchangerates-app-id` | `value` |
| `prod-homechef-google-weather-api-key` | `kv/homechef/homechef-api/fe3dr-google-weather-api-key` | `value` |

Weather is a naming example, not part of this pilot. Cross-app readers still
need a coordinated ownership decision; naming does not grant access.
Use the same product identifier under the BFF prefix for BFF-owned secrets.
Keep development in a separately authorized environment; this pilot only
renders when the environment prefix is `prod` and namespace is `homechef`.

## Decision

The installed ESO CRD supports `spec.data[].sourceRef.storeRef`. Use that
per-key override for the pilot, keeping the existing single ExternalSecret
owner and Kubernetes target `homechef-api-secrets`. This avoids a bundle split
and preserves API/worker environment references. Other entries continue to
use `ClusterSecretStore/gcp-secret-store`.

The pilot is one existing static credential, with an existing 1-hour ESO
refresh interval and no added application-request-time OpenBao calls. No new
pods, storage or external services are required; ESO adds one backend read per
refresh. Payload size has not been inspected. Production peak request rate is
not needed for this configuration-only change because access remains through
the existing Kubernetes Secret.

A compromised unrelated service account must not read this provider credential:
the namespaced store uses the existing API role restricted to its own prefix.
The copy requires an authorized writer; the API role remains read-only.

ESO fetches the bundle as a unit: failure of either GCP or OpenBao prevents
that refresh. `deletionPolicy: Retain` preserves the last good target. Existing
pods and restarts can use that Secret; provisioning without it cannot succeed.
This pilot does not improve the runtime availability of the provider itself.

## Cutover gates and procedure

1. Verify isolated restore evidence, snapshot retention and alert delivery;
   agree the observation window and recovery objectives in #1159. Daily
   successful snapshot jobs alone do not satisfy this gate.
2. Use the operator-issued temporary-token script below (explicitly requested
   for this migration), or an authenticated console operator, to copy the exact
   GCP value to the pilot path/field above. Do not rotate it,
   expose it in output, or commit it. Compare source and destination in memory,
   reporting only match/mismatch. Record the source and destination versions.
3. Verify the API read role can retrieve that field and the bytes match both
   the GCP source and existing Kubernetes target. Keep GCP versions enabled.
4. Set `openbao.exchangeRatePilot.enabled: true` in the production values
   through a reviewed GitOps change. The flag defaults to false for preparation.
5. Confirm live per-key sourceRef/path/property, ESO Ready and refresh time,
   preserved target keys/values and healthy API/worker. Verify exchange-rate
   success/fallback and restart behavior. Test missing-path/outage behavior in
   isolation; do not disrupt production OpenBao.
6. Record evidence and observation start/end in #1159. Check the pilot item
   only when all acceptance checks pass.

Rollback: set the flag false through GitOps and verify ESO reads GCP again,
reconciles the target, and API/worker remain healthy. Preserve matching source
bytes throughout. Rehearse before accepting the batch. Do not delete either
copy or remove GCP IAM as part of this pilot.

## Current evidence and remaining access

On 2026-09-27, the active account was `unidevidp@gmail.com`, project
`tesseracthub-480811`, context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`.
Both homechef SecretStores and all 12 GCP ExternalSecrets were Ready;
OpenBao had three Ready pods and a recent successful snapshot job.
No successful isolated restore evidence was found in the reviewed docs/issues.

The existing API role can authenticate but cannot write. The user requested a
separate temporary-writer migration script; the operator must issue its scoped
token. The script does not use bootstrap credentials, a revoked root token,
service-account impersonation, or a permanent application write grant.


## Temporary-writer script

`scripts/migrate_fe3dr_secret.py` uses Python's standard library and `gcloud`.
It intentionally migrates only this pilot; do not widen the policy or substitute
payment/PII secrets. Subsequent batches require their own mapping and consumer
review. The OpenBao identifier is `fe3dr-openexchangerates-app-id`.

1. An authorized OpenBao operator installs
   `scripts/policies/fe3dr-migrate-openexchangerates.hcl` as policy
   `fe3dr-migrate-openexchangerates`. It grants **create/read on one exact path**
   and token self-inspection/revocation, with no overwrite, delete or admin rights.
   Review the policy content: checking a token's policy name cannot prove that
   an administrator installed the correct contents.

   ```sh
   bao policy write fe3dr-migrate-openexchangerates scripts/policies/fe3dr-migrate-openexchangerates.hcl
   ```

2. In an operator-authenticated shell, capture a dedicated service token without
   printing it. Do not enable shell tracing. This replaces that shell's current
   `BAO_TOKEN`; use a separate administrative session for later policy cleanup.

   ```sh
   set +x
   export BAO_TOKEN="$(bao token create -policy=fe3dr-migrate-openexchangerates -no-default-policy=true -ttl=10m -explicit-max-ttl=15m -renewable=false -field=token)"
   ```

   Alternatively, run the script without `BAO_TOKEN` and enter the issued token
   at its hidden prompt. Never supply a token on the command line or in chat.
   The script rejects root/extra policies and remaining TTL above 15 minutes.
   It revokes this dedicated token on success and failures after connecting to
   the validated endpoint. Invalid arguments/addresses and hard process kills
   can prevent cleanup; the issuer must revoke unused tokens and enforce TTL.

3. Use a verified TLS endpoint or a loopback port-forward to the active service:

   ```sh
   KUBECONFIG=~/.kube/gke-prod kubectl -n openbao port-forward svc/openbao-active 18200:8200
   ```

   Confirm the active kubeconfig context first. Keep the forward in a separate
   terminal. The script verifies TLS for HTTPS, refuses non-loopback plaintext,
   disables environment proxies and refuses HTTP redirects.

4. Inspect the no-access plan, then choose an enabled numeric GCP version:

   ```sh
   python3 scripts/migrate_fe3dr_secret.py
   gcloud secrets versions list prod-homechef-openexchangerates-app-id --project=tesseracthub-480811 --filter=state:ENABLED --format='table(name,state)'
   ```

5. Substitute that version for `VERSION` below. `--account` must equal the active
   gcloud account. The source project and secret are hardcoded to this pilot.

   ```sh
   python3 scripts/migrate_fe3dr_secret.py --execute --version VERSION --account unidevidp@gmail.com --bao-addr http://127.0.0.1:18200 --prepare-app
   unset BAO_TOKEN
   ```

   It checks the pinned version is enabled, captures base64 on stdout and decodes it in memory, preserves UTF-8 including newlines, and writes JSON field `value`.
   No secret enters an argument, file, log or subprocess environment. Empty or
   non-UTF-8 input fails. The destination read must be absent or exactly equal;
   different content is refused. Writes use KV v2 `cas: 0`, so a concurrent or
   soft-deleted existing key cannot be overwritten. A read-back must match the
   source bytes and newly written version. A timeout after writing is reported
   as failure; rerun with a fresh token and the same source version to verify
   the existing value without creating another version.

6. Only after successful copy **and token revocation**, `--prepare-app` appends
   the pilot enablement to local `charts/apps/homechef-api/values-prod.yaml`.
   Existing unrelated content is preserved, reruns are idempotent, and conflicting
   OpenBao configuration requires review. It does not commit, push, apply or
   restart anything. Omit this flag for copy/verification alone.

7. Review the diff, run the tests below, and deploy the chart plus production
   values through the owning repository/Argo CD workflow after the cutover gates.
   ESO supplies `OPENEXCHANGERATES_APP_ID` to the existing API/worker Secret
   references; no application code or permanent write access is needed.
   Confirm the live per-key sourceRef, Ready/refresh status, target byte equality
   in memory, workload readiness and provider behavior before marking complete.
   A local switch or successful copy does not prove live app connectivity.

8. Stop the port-forward, clear the token from the calling shell, and have the
   issuer remove the one-off policy after all issued tokens are revoked/expired.
   Policy removal alone does not revoke tokens. Record metadata-only evidence
   in #1159. Never delete the GCP rollback copy during this step.

Validation:

```sh
python3 -m pytest -q tests/test_migrate_fe3dr_secret.py tests/test_homechef_openbao_pilot.py tests/test_homechef_openbao_access.py
ruff check scripts/migrate_fe3dr_secret.py tests/test_migrate_fe3dr_secret.py
```


## Pilot staging result, 2026-09-27

The authorized temporary Kubernetes auth role was bound only to
`openbao/openbao-bootstrap`, with token TTL/max TTL/explicit max TTL all 600s,
no default policy and only the exact-path migration policy. It was issued via
the documented bootstrap route because no console session was available.
After copying, the script revoked the writer token. A separate login with
`homechef/homechef-api` and its existing read-only role retrieved the destination;
source GCP version 1, OpenBao version 1 and the current Kubernetes field matched.
The verifier token and bootstrap token were revoked; both temporary role and
policy were confirmed absent after cleanup. No permanent write access changed.

The first execution exposed a gcloud compatibility bug: `--out-file=-` created
a local file named `-` instead of returning bytes. The script rejected empty
stdout before any OpenBao write. That unintended file was removed without
printing its contents; it was not committed. The corrected implementation uses
`--format=get(payload.data)` and strict in-memory base64 decoding. Regression
coverage rejects file-output flags. The retry succeeded.

This is staging evidence, not proof of live ESO cutover, provider functionality,
restore, outage handling or observation-window completion. Keep #1159 open.


## Reviewed batch extension

The user subsequently authorized migration of the reviewed application candidates
and deletion of their GCP sources only after successful migration. The 36
candidates have been staged to 38 exact paths (admin allowlist and HMAC have both
API and BFF copies). Copying is not consumer cutover: 18 direct-runtime entries
and six coordinated entries remain dependent on their existing GCP consumers.

`scripts/migrate_fe3dr_reviewed.py` accepts a local metadata-only JSON plan:

```json
[{"source":"prod-homechef-jwt-secret","version":"1","targets":["homechef/homechef-api/fe3dr-jwt-secret"]}]
```

It allows only reviewed production app names and exact matching identifiers under
the API/BFF prefixes. Platform, held, development and shared-service entries are
rejected. `--policy` produces the exact-path create/read ACL for an operator-issued
`fe3dr-migrate-reviewed` token; `--execute --account <account> --journal <file>`
copies and verifies each target and records metadata only, revoking the token
in a finally block. Reruns refuse changed destinations. Runtime writers must be
quiesced or reconciled at their future cutover; staging alone is not authority to
delete the GCP source.

The static batch switches 11 API keys and two BFF keys (12 unique GCP entries).
API and worker use `openbao.staticSecrets.enabled`; BFF mappings are explicit
per-key sourceRef entries in the namespace ExternalSecret. Unrelated/shared keys
stay on GCP. Pod-template annotations force a fresh API/worker/BFF rollout to
verify startup with the unchanged values. Rollback requires reverting both API
production enablement and the two BFF source mappings through GitOps.

Deletion must follow live ESO source/refresh checks, target equality and healthy
fresh workloads, an all-namespace consumer scan, source version recheck and a
verified recoverable capture. Record exact deleted sources and recovery location
in #1159. Staged runtime/coordinated entries are excluded from static-batch
cleanup. No platform, unknown-use or unverified secret may be deleted by inference.
