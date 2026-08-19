# AgentGateway Registry ownership migration capture

Captured on 2026-08-19 from:

- GCP account: `unidevidp@gmail.com`
- project: `tesseracthub-480811`
- context: `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`
- namespace: `agentgateway-system`
- rollback source commit: `158c176e6261c53e7d89e2b33d1d72024eb3da6e`

The rollback commit contains the exact Helm templates and values needed to
recreate these resources. Hashes are SHA-256 over canonical JSON containing
only `apiVersion`, `kind`, `metadata.name`, `metadata.namespace`, and `spec`.
No Secret values, tokens, status, or managed fields are captured.

| Kind | Name | SHA-256 |
|---|---|---|
| AgentgatewayBackend | ai-zitadel-jwks | `2fd1566256f14a4c7b9dcfa8c9ae3b00ac569b5aa3d75b47aafc11f44583574b` |
| AgentgatewayBackend | devai-anthropic | `761c9e30e6803b63041bf262293a2b0596af450b0e4761573917cc7c1149d536` |
| AgentgatewayBackend | devai-gemini | `cc98afa90e463999679545b437d523c50557be632978b195a7f391f3a1d079d7` |
| AgentgatewayBackend | devai-groq | `3fed6e8b398621b18f3a343a23b26e5210aa28f191869a88c3e269d93251c7eb` |
| AgentgatewayBackend | devai-nemoclaw | `ca279b1e5287c0666b06b434683ceb05dc8b3aad2dc2c3913fb21cac56544f87` |
| AgentgatewayBackend | devai-openai | `c7af112072e138cae3e0f62590b19023c359159662f973214c33e8d019777bcc` |
| AgentgatewayBackend | devai-openrouter | `8f189d6b129a3a5c6574a79e9a8f0fc49da2cafa8bc7de0d5a15e49fcb092b04` |
| AgentgatewayBackend | devai-vertex | `74cc67aa85f1197b45b1a21d38bd979505ce66eeb9acc291d4b8c96d3dca1cc3` |
| AgentgatewayBackend | kora-conversation-providers | `9e48f55c968519ae886899c83fb12aa576482ae8904629ef28ef6c2efe7f9743` |
| AgentgatewayBackend | kora-embedding-providers | `54bcfa31c6f68b7d1c37882075cf6d09b54858f209d4280b062627ea27050733` |
| AgentgatewayBackend | kora-structured-providers | `67f6e9b7aa5d05d8a36d08c96d6f8f6a4f41f6bd493f27b0a67c69dfa5a3e7e0` |
| AgentgatewayBackend | mcp-zitadel-jwks | `0ecdb72e43523481f21dbaa3137761c729a5f850c400435830ffdca1a3e5cf5d` |
| AgentgatewayPolicy | ai-public-oauth | `308578eb1754823b918b520ab4d0b97abd404dc5f63b5899346b9a93b7307bd8` |
| AgentgatewayPolicy | ai-public-observability | `2522ed982b6ddc129fb0d44c69106067844cafa7b2ab1439d43992025d5ce1ab` |
| AgentgatewayPolicy | devai-ai-observability | `cacb925f46c02897a3c9243b8e4464495fc98227aaf6576b3dc1717cea677a10` |
| AgentgatewayPolicy | devai-ai-routes | `5144f5bfccd6cf2c110fa1eaee5a34e2814896553ba923f74a7d51714c9e1ef8` |
| AgentgatewayPolicy | devai-ai-traffic | `18f23b23d23e23e215f8f025047fa080ac85a5408515ace71c28415cad03577f` |
| AgentgatewayPolicy | kora-ai-guardrails | `741afbcbd94929c7fbe60040f4968d19214c3eab3ae34bf5e7d7c7b4c35949d2` |
| AgentgatewayPolicy | kora-ai-observability | `d44510df82c1ffe02534921819c9f59941ccd39d2ae9e06ac3ba768d1a27487f` |
| AgentgatewayPolicy | kora-ai-traffic | `eaea4497e58e580908aaab5560df41ee3854efb1da98c33f07f68da25dfedbc9` |
| AgentgatewayPolicy | mcp-public-oauth | `0359ba408e1dace4d4d311e080397334f7ea19d501e44ff7e933d9197fdcffd8` |
| AgentgatewayPolicy | mcp-public-observability | `08ffd382fe194164712ed79ee654d85df3b258f98026600eaf8fb3cfc998e809` |
| HTTPRoute | devai-ai | `6d82e0d157e095cacdfb2c2a71115111741108515de1e6d33ac913b7e97460c3` |
| HTTPRoute | kora-ai | `0aeeabcb4429ded2112c6bd43726808802bec438674384920217f08d50e85185` |

Registry-generated MCP backends and routes are intentionally excluded because
they already carry `app.kubernetes.io/managed-by=agentic-registry` and do not
participate in the ownership transfer.

## Verified handoff

Phase one completed on 2026-08-19:

- the import API returned `count: 24`;
- route-sync verified the Registry export count and SHA-256 digest before apply;
- the first combined export contained 124 resources: the 24 platform resources
  above plus the existing Registry-generated MCP backends and routes;
- the `agentgateway-mcp`, `ai-gateway`, and `kora-ai` Gateways remained Accepted
  and Programmed.

Phase two makes Registry ownership the chart default. A one-time handoff Job
waits for both former Helm applications to publish their ownership markers and
for all 24 resources to carry the Registry owner label. It then removes only
stale Argo/Helm tracking annotations. Registry pruning refuses any export below
the permanent 24-resource platform floor.

## Rollback

Set `registryOwnership.enabled=false` in each of these charts to restore the
tested Helm renderings without reconstructing resource definitions:

- `charts/apps/devai-ai-gateway`
- `charts/apps/kora-ai-gateway`
- `charts/apps/agentgateway-route-sync`

Also set `registry.prune=false` in `agentgateway-route-sync` before rolling back
ownership. The original source remains available at the rollback commit named
above, and the exact canonical hashes in this document remain the comparison
baseline.
