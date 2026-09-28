# Planning Poker OpenBao migration

Tracked in [#1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

One populated source, `prod-planning-poker-token-secret`, feeds `TOKEN_SECRET` in
`planning-poker/planning-poker-api`. Migrate to
`planning-poker/app/planning-poker-token-secret` without changing bytes: rotation
would invalidate issued user and participant tokens. The persistent namespace
reader has one exact read-only path; the temporary migration writer has only
create/read on that path with a fifteen-minute TTL and token self-revocation.

Baseline: API and web each have two ready replicas. Health, database readiness,
stats and public UI return 200. A synthetic nonexistent user with a valid signature
reaches the database lookup and returns 404; unsigned and invalid-signature
controls return 401. No account, room or external message is created by this test.

Slack integration is unconfigured and is not claimed as tested. Future Slack
credentials must use product-prefixed OpenBao paths with reviewed reader grants.
Postgres is operator-managed; no populated GCP database credential was found in
this product's inventory. Shared registry/platform dependencies remain separate
migration batches under the zero–Secret Manager target.

Before deletion: archive metadata/IAM/enabled versions with KMS encryption,
verify remote ciphertext and decryption, copy pinned versions with CAS=0 and byte
readback, test reader isolation, switch through GitOps, force fresh ESO reads,
compare whole-Secret hashes and images, repeat functional checks, test isolated
snapshot restore and retire temporary access. Preserve deployed image parameters.

Before deletion rollback may restore old references; afterward the encrypted
recovery archive is required. A stopped OpenBao must not prevent independent
recovery access. No additional persistent service is introduced.

The consumer chart uses `openbao-planning-poker-production` and the KV `value`
property. Optional Slack paths use the same product prefix but require separately
reviewed grants before enabling Slack. The unused GCP database-secret default is
removed. Cutover retires the temporary writer in Git; live role/policy removal
must follow selective ServiceAccount pruning and capture of the retired grants.

Recovery source archive:
`gs://tesseract-prod-backups-in/openbao/planning-poker-migration/20260928T063153Z/gcp-sources.json.gz.kms`.
The archive contains source metadata, IAM and enabled versions, and its remote
ciphertext/decryption matched before migration.

Completed: access #1233 and cutover #1234 merged; product rules merged in
`tesserix/planning-poker#19`. The single GCP original was deleted after verified
archive, reader scope, isolated restore and functional acceptance. Post-deletion
fresh ESO read, whole-Secret equality, unchanged images/Argo parameters and all
seven functional checks passed. Temporary ServiceAccount/role/policy are absent.
Backup `20260928T064623Z-4cdcb6f9be89` restored in 19.689 seconds, with three
verified backups retained and pruned objects absent. Total completed migration
cleanup is 274 records; Support Platform's four originals remain retained.

Argo's `RespectIgnoreDifferences=true` initially preserved the old remoteRef while
changing the store. A selective ExternalSecret sync without that option applied
the reviewed path/property. Verify actual ESO fields and fresh reads after sync;
a healthy Deployment alone does not establish that ESO uses the new provider.
