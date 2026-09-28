# Company and console OpenBao migration

Tracks [#1209](https://github.com/tesserix/tesserix-k8s/issues/1209).
Status: access configuration prepared locally; no values copied and no consumer
cutover or source deletion completed for this group.

The company application has seven remaining GCP references, with ten confirmed
ESO bindings across the Tesserix and Mark8ly namespaces. Use production paths
under `tesserix/app/` and identifiers beginning `tesserix-`.

| GCP source | OpenBao identifier | Confirmed consumers |
| --- | --- | --- |
| `prod-internal-service-key` | `tesserix-internal-service-key` | company |
| `prod-tesserix-internal-api-token` | `tesserix-internal-api-token` | company, Mark8ly admin |
| `prod-github-token` | `tesserix-github-token` | company |
| `prod-marketplace-content-admin-key` | `tesserix-marketplace-content-admin-key` | company onboarding |
| `prod-argocd-auth-token` | `tesserix-argocd-auth-token` | company |
| `prod-tesserix-session-encrypt-key` | `tesserix-session-encrypt-key` | company, console, tesserix-auth-bff |
| `prod-tesserix-sendgrid-webhook-secret` | `tesserix-sendgrid-webhook-secret` | company event verification |

The session key has THREE live consumers. Older comments in the company/console
charts incorrectly describe only two. The third ExternalSecret is
`tesserix/tesserix-session`, owned by `external-secrets-resources` and declared in
`external-secrets/prod/tesserix/externalsecret.yaml`. Preserve identical bytes
across all three; no session-key rotation is part of this migration.

The Tesserix reader can read exactly these seven paths. The Mark8ly reader can
read only the internal API token. Neither can list, create, overwrite or delete.
The temporary writer is namespace-bound, uses a fifteen-minute TTL and has only
create/read on the seven exact destinations, plus self-lookup/revocation. The
migration script validates pinned versions, uses CAS=0 and refuses differences.
Retire the writer and its issued tokens once staging and readback are complete.

Before deletion, finish shared-consumer and cold-start review beyond the ESO
inventory; absence of another ESO binding does not establish exclusive ownership.
Archive all recoverable enabled versions, metadata and IAM under KMS encryption.
Test provider access and authenticated application flows without sending email,
changing content, creating deployments or modifying customer records. Verify
fresh ESO synchronization, whole-Secret equality, all three session readers,
Mark8ly internal API access, unchanged images, isolated restore and independent
recovery before retiring any source.

The product repository is `tesserix/tesserix-home`. Its secrets API already
defaults new writes to OpenBao but retains an explicitly selectable GCP backend
for remaining sources. Do not remove that backend while other products still
need it. The old GCP metadata health helper has no production function callers
in the current source scan; verify imports and tests before removing the unused
SDK dependency. Keep the portal's OpenBao metadata-only health checks read-blind.
