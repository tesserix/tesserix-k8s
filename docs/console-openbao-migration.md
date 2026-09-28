# Console OpenBao migration

Tracks [#1209](https://github.com/tesserix/tesserix-k8s/issues/1209).
Status: access configuration prepared; no values copied or consumer cutover yet.

The twelve sources below currently have twelve ESO bindings, all through
`tesserix/console-secrets`. The shared session key was already migrated with
company; keep its existing `openbao-tesserix-production` reference unchanged.

| GCP source | OpenBao path |
| --- | --- |
| `prod-zitadel-console-client-secret` | `console/app/console-zitadel-client-secret` |
| `prod-console-operator-token-key` | `console/app/console-operator-token-key` |
| `prod-console-crm-erasure-hash-key` | `console/app/console-crm-erasure-hash-key` |
| `prod-console-login-throttle-hash-key` | `console/app/console-login-throttle-hash-key` |
| `prod-console-login-client-token` | `console/app/console-zitadel-login-client-token` |
| `prod-console-identity-reader-pat` | `console/app/console-zitadel-identity-reader-pat` |
| `prod-console-entitlements-reader-client-id` | `console/app/console-zitadel-entitlements-reader-client-id` |
| `prod-console-entitlements-reader-client-secret` | `console/app/console-zitadel-entitlements-reader-client-secret` |
| `prod-tesserix-stripe-restricted-read-key-test` | `console/app/console-stripe-restricted-read-key-test` |
| `prod-tesserix-stripe-restricted-read-key-live` | `console/app/console-stripe-restricted-read-key-live` |
| `prod-tesserix-stripe-write-key-live` | `console/app/console-stripe-write-key-live` |
| `prod-tesserix-stripe-write-key-test` | `console/app/console-stripe-write-key-test` |

Use a separate namespace-bound console reader limited to these twelve paths.
The temporary writer permits create/read only, with a fifteen-minute TTL and
self-revocation. Archive enabled versions, metadata and IAM using client-side KMS
encryption before copying pinned values with CAS=0 and exact readback.

These keys include encryption and erasure-register material. Preserve bytes;
rotation would invalidate stored tokens or erase the ability to honor historical
CRM erasures. Verify existing behavior first, then fresh ESO reads, whole-Secret
equality, functional identity/session/provider checks, isolated restore and writer
retirement before deleting any originals. Provider checks must not create Stripe
objects, charges, identity users, sessions or customer records.
