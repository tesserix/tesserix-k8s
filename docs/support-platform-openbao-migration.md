# Support Platform OpenBao migration

Tracked in [#1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

Four product-owned sources (Hugging Face token, Otto session signing, SendGrid
API key and platform MCP key) feed six bindings in `support-platform` and
`agentgateway-system`. The MCP serves company information and contact capture;
its product name does not make its credential a critical platform exception.

Destinations use `support-platform/app/support-platform-<secret>`. The product
namespace reader can read all four exact paths; the gateway reader can read only
the MCP key. Neither can write or access other products. A temporary migration
identity has create/read access only to these four paths, a fifteen-minute TTL,
and no overwrite or deletion rights. Preserve values with pinned source versions,
CAS=0 and byte equality checks. Retire this identity after acceptance.

Baseline Otto, router and MCP readiness return 200. MCP initialize returns 401
without a key and 200 with the existing key. Other product MCP keys in this
namespace remain with their owners and are migrated with those products.

Before deleting originals: capture metadata, IAM and all enabled versions in a
KMS-encrypted remote archive; verify ciphertext and decryption; stage credentials;
verify reader isolation; switch consumers through GitOps; force fresh ESO reads;
compare whole-Secret hashes and deployed images; repeat functionality checks and
an isolated snapshot restore. No credentials enter repository files or logs.
Existing reader references provide rollback until deletion; thereafter recovery
requires the encrypted archive and KMS access. No persistent service is added.
