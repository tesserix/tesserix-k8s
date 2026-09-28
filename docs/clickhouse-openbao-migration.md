# ClickHouse OpenBao migration

Track in [issue #1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

Three reviewed sources map to `clickhouse/app/clickhouse-otel-password`,
`clickhouse/app/clickhouse-observer-password` and
`clickhouse/app/clickhouse-sre-writer-password`. The observability namespace
reads all three; tesserix reads only the existing shared OTel password.
Langfuse uses the ClickHouse reader explicitly for its shared password, keeping
its own reader limited to Langfuse credentials.

The boundary is namespace-bound Kubernetes authentication and exact read-only
KV policies. No cross-product wildcard or permanent writer is introduced.
Temporary staging access must be exact-path create/read, short-lived and removed
after copy. All three ESO consumers refresh every five minutes. Existing data,
users, privilege levels, images, replica counts and application keys are unchanged.

Baseline: all three users pass a read-only SELECT 1; wrong-password controls are
rejected. Both data replicas and all three coordination nodes are Ready. No
Terraform ownership was found in the storage/app-secrets states. Before deleting
originals, archive pinned versions and IAM under KMS, verify all copies and fresh
ESO reads, test provider authentication and isolated restore, and remove grants.
Then verify fresh reads and application health after deletion.
