# Helivanta private file storage

Tracking: [Helivanta #1105](https://github.com/tesserix/helivanta/issues/1105),
[epic #979](https://github.com/tesserix/helivanta/issues/979).

This change prepares storage; it does not activate an upload API or deploy a
scanner/worker. Production Terraform follows the
[Atlantis control-plane workflow](../terraform-new/README.md).

## Review target

Active discovery: project `tesseracthub-480811`, account
`unidevidp@gmail.com`, primary region `asia-south1`; Kubernetes context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, namespace
`helivanta`. No imperative cloud changes have been made for these files.

The `17-helivanta-files` project owns only these new resources in the separate
`stacks/prod/helivanta-files` state. It reads the existing regional keyring;
shared storage, secrets, registries and backup resources stay in their owning
states. No resource has been applied under the earlier shared-stack proposal,
so no Terraform state move is needed. The earlier plan (56 additions, 2 updates,
11 deletions) is unsafe and must never be applied. Request a new saved plan for
`17-helivanta-files`; never use targeted apply to bypass the unrelated drift.

The intended additions are four regional buckets, one CMEK with its storage
service-agent grant, one custom exact-object-read role and ten bucket-scoped
workload grants (17 resources). The saved Atlantis plan must be checked for
unrelated updates, deletion or replacement before apply.

| Environment | Quarantine | Released |
|---|---|---|
| Production | `tesseracthub-480811-helivanta-prod-quarantine` | `tesseracthub-480811-helivanta-prod-released` |
| Synthetic verification | `tesseracthub-480811-helivanta-verification-quarantine` | `tesseracthub-480811-helivanta-verification-released` |

The key is `helivanta-private-files` in the existing regional keyring.
The CNPG backup bucket is separately owned and is never application storage.
Uniform bucket access, enforced public-access prevention, versioning,
seven-day soft deletion, `force_destroy=false` and Terraform deletion guards
protect the new resources. No CORS or automatic deletion policy is added.
Retention/legal-hold policy must be reviewed before destructive cleanup;
Terraform deletion guards do not replace IAM or that review.

## Runtime identities

| Kubernetes service account in `helivanta` | Production access |
|---|---|
| `helivanta-api` | Quarantine create/read; released read |
| `helivanta-document-worker` | Quarantine read; released create/read |
| `helivanta-file-verifier` | None; create/read only in verification buckets |

`helivantaPrivateFileRead` permits `storage.objects.get` only, with no list.
Create uses `roles/storage.objectCreator`, without overwrite or deletion.
Bindings use exact GKE workload principals rather than static keys or broad
project grants. The API cannot create a released object. GCS service-agent
encryption permission is bound only to this key.

Activation requires GitOps service accounts, metadata-server access through
Istio, verified workload identities, current-definition ClamAV and the owning
domain's transactional metadata/outbox and Temporal processing. Confirm the
project's GCS Data Access audit configuration with its owning stack before
serving confidential files; do not introduce competing project audit ownership.
Object prefixes are identifiers, never access grants. Authenticated delivery
must enforce current tenant/hospital/record permissions, exact generations,
private caching and attachment response headers.

## Validation and rollback

Native Terraform tests use mocked Google providers and issue no cloud calls:

```sh
terraform -chdir=terraform-new/stacks/17-helivanta-files init -backend=false -input=false
terraform -chdir=terraform-new/stacks/17-helivanta-files validate
terraform -chdir=terraform-new/stacks/17-helivanta-files test
```

Real GCS/workload-identity and end-to-end scan/delivery verification remain
required after approved provisioning, using only synthetic files and isolated
verification ownership. No customer files are allowed in acceptance fixtures.

On runtime rollback, disable new upload acceptance and restore the previous
workload while retaining private metadata, objects and keys. Do not drop file
tables, delete storage or destroy the key as an application rollback. Any
retirement requires explicit approval, captured recoverable state and reviewed
retention/hold handling.
