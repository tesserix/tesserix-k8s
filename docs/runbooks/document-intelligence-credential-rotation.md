# Document Intelligence credential rotation

This runbook rotates the Kora-development OCR workload-identity credential
without interrupting valid requests and rotates the generic DevAI Langfuse
project credential pair when exposure is suspected. Never place values,
signatures, upload URLs, document content, or trace content in this runbook, a
terminal transcript, CI, or an issue.

## Scope and approval

The procedure changes production-managed Secret Manager versions and triggers
GitOps-managed workload rollouts. Obtain explicit approval for the named
rotation and record the Argo revision, ExternalSecret readiness, and workload
readiness before making a change.

| Consumer | Secret Manager resource | Purpose |
| --- | --- | --- |
| DevAI Kora OCR adapter | `dev-kora-document-intelligence-signing-key` | Matching HMAC key used to sign sandbox OCR requests. |
| Sandbox OCR APIs | `dev-kora-ocr-workload-identity-keys` | Registered key-ID-to-product/key verifier mapping. |

The verifier mapping has the form `key_id=product:hex_key` and supports
multiple entries during rotation. The DevAI configuration currently uses key ID
`kora-dev-v1`; a new key must use a new ID, for example `kora-dev-v2`. Never
replace a verifier value with only the new key before the caller has migrated.

The generic DevAI Langfuse pair consists of
`prod-devai-langfuse-public-key` and `prod-devai-langfuse-secret-key`. The
DevAI Kora OCR evaluation route instead uses
`dev-kora-langfuse-public-key` and `dev-kora-langfuse-secret-key` through the
`devai-langfuse-secrets` ExternalSecret. The Kora development pair is never a
fallback for a production trace route.

## Threat boundary

The protected assets are tenant documents, results, and the ability to submit a
signed OCR request. Threats include a leaked HMAC key, a cross-product trace
credential, and a compromised in-cluster caller. Product authentication and
tenant derivation occur in the product adapter; OCR validates the short-lived
signed envelope and then applies product/tenant scope. A bad rotation must fail
closed with `401` or readiness failure, never accept an unsigned request.

## Kora-development OCR rotation

1. Record current Kargo Freight, Argo revision, OCR sandbox API readiness,
   DevAI rollout state, and ExternalSecret `Ready` conditions. Do not read or
   print secret versions.
2. Generate a new cryptographically secure 32-byte-or-longer HMAC key and a
   new key ID. Store it only through the approved Secret Manager write path.
3. Update the OCR verifier secret with **both** the current mapping and the new
   `kora-dev-v2` mapping. Wait for External Secrets and sandbox upload/job API
   rollouts to become Ready; the old key remains valid only for overlap.
4. Update `dev-kora-document-intelligence-signing-key` to the matching new key
   and update DevAI's key ID through reviewed GitOps. Wait for `devai-api` and
   `devai-api-worker` to complete their secret-triggered rollout.
5. Submit one synthetic, non-sensitive PDF through the DevAI Kora OCR adapter.
   Verify upload, inspection/acceptance, durable job dispatch, terminal result,
   and evidence/validation metadata. Record only IDs, state, provider/model,
   duration, confidence band, warnings, and error/retry count.
6. Wait at least 60 seconds after the final old-key request, exceeding the
   maximum envelope clock-skew window. Remove the prior verifier mapping and
   confirm the new key works while an unsigned upload returns `401`.
7. Record completion and safe validation evidence in the OCR runtime issue.
   Retain no old key material in local files.

If the new signer cannot validate, do not restore a known exposed key. Leave
the prior verifier entry only for the bounded overlap, stop DevAI OCR traffic if
necessary, and correct the new signer/verifier pairing through GitOps.

## Generic DevAI Langfuse pair rotation

1. Create a replacement DevAI project credential pair through the approved
   Langfuse administration workflow. Store it as new Secret Manager versions of
   the existing generic DevAI resources. Do not rotate Kora keys as a side
   effect.
2. Wait for the Langfuse platform ExternalSecret and dependent workload rollout
   to become Ready. Validate a content-free health check and one non-sensitive
   DevAI trace.
3. Confirm the DevAI Kora OCR adapter still maps to the Kora-development pair,
   not the generic pair. Inspect ExternalSecret references/readiness only; never
   read Kubernetes Secret data.
4. Record project, environment, Secret Manager version identifiers, rollout
   readiness, and trace ID in the change record, never credentials or payloads.

## Completion evidence

Rotation is complete only when:

- Both affected ExternalSecrets are `Ready` and name the intended Secret Manager
  resources.
- DevAI API/worker and sandbox OCR API/worker deployments are fully Ready.
- A Kora-dev signed synthetic OCR lifecycle completes and unsigned upload is
  rejected with `401`.
- The resulting trace appears only in the Kora-development Langfuse project
  with redacted operational metadata.
- The old verifier key is absent after overlap and no workload references the
  retired credential version.

## Related material

- OCR repository ADR-0009, signed workload identity envelope
- [DevAI OCR integration tests](../../tests/test_devai_document_intelligence_integration.py)
- [AI trace pipeline](../ai-trace-pipeline.md)
