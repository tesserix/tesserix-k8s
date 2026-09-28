# BeautyAndCruor OpenBao migration

Tracked in [#1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

Three confirmed sources feed the `tesserix/beautyandcruor-admin` Kubernetes Secret:

| GCP source | OpenBao path | Application use |
| --- | --- | --- |
| `prod-bac-admin-password-hash` | `beautyandcruor/app/beautyandcruor-admin-password-hash` | PBKDF2 password verifier |
| `prod-bac-admin-session-key` | `beautyandcruor/app/beautyandcruor-admin-session-key` | Admin cookie signature |
| `prod-bac-admin-github-token` | `beautyandcruor/app/beautyandcruor-admin-github-token` | Scoped content access |

Keep all bytes unchanged. The reader is bound to `tesserix` and these exact paths;
the temporary writer has create/read only and a fifteen-minute TTL. No runtime
GCP SDK cutover is needed: the enquiry sidecar consumes the existing Secret keys.

The enquiry Resend key already reads OpenBao through `openbao-fe3dr-appdeps`.
Preserve its path and target bytes. A fourth GCP source,
`prod-beautyandcruor-cloudflare-token`, has an enabled version but no confirmed
consumer in the current inventory. Cloudflare token verification reports it as
expired (HTTP 200 with token status `expired`). It remains a separate operational-credential
review; lack of an explicit ESO binding is not proof that it is unused.

Baseline: deployment ready; public UI at `beautyandcruor.com`, sidecar health,
admin login page, signed credits/sequence reads all pass. Unsigned and invalid
cookies return 401. Password-verifier format and iteration count are validated;
no password guessing, content writes or emails are performed. The old
`beautyandcruor.tesserix.app` hostname is not the live public route.

Before source deletion: pin versions, capture metadata/IAM/enabled values to a
KMS-encrypted remote archive, verify ciphertext/decryption equality, stage with
CAS=0 and byte readback, test namespace scope, verify isolated snapshot restore,
cut over with GitOps, force fresh ESO reads, verify both admin and enquiry Secret
hashes, preserve image parameters, repeat functional checks and retire write
access. Never bulk-sync parent Applications. On initial cutover, use a selective
ExternalSecret sync without `RespectIgnoreDifferences=true` if Argo preserves old
remoteRef fields, then verify the actual path/property and refresh status.

Source archive for the three admin credentials:
`gs://tesseract-prod-backups-in/openbao/beautyandcruor-migration/20260928T070857Z/gcp-sources.json.gz.kms`.
Remote ciphertext and decrypt equality were verified.
