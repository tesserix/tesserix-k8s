# Optional consumer email OTP deployment

Email OTP is opt-in for an operator-owned consumer organization. Omitted policy
preserves existing behavior; explicit false revokes the method, including pending
completion. This change does not enable it for any tenant or replace existing
staff MFA/social login. Independent hospital tenant preferences require their own
verified organization binding; a shared consumer organization has one policy.

The central Login V2 service owns the UI flow. Zitadel owns identity, mailbox
verification, delivery, OTP verification, sessions and OIDC callbacks. Mailbox
verification never establishes patient identity or clinical authorization.

## Authentication state

Use the dedicated `zitadel-email-valkey` instance in namespace `zitadel`. The
general-purpose cache has evictable keys and passwordless ACL usernames and is not
suitable for credential-bearing OTP state. The dedicated instance has a password,
no eviction, three members, AOF and a minimum healthy replica for writes. Existing
cache and queue consumers are unchanged. Memory pressure and dependency failures
reject email sign-in; there is no in-process fallback.

All login replicas use `CONSUMER_EMAIL_VALKEY_URL` from the
`zitadel-email-valkey` Kubernetes Secret. Its OpenBao source is the exact path
`zitadel/prod/app/zitadel-email-valkey-password`, property `value`, containing a
new 64-character hexadecimal password. Do not overwrite an existing different
value or rotate existing credentials as part of deployment. The dedicated reader
role is read-only and bound to `zitadel-email-production-reader` in `zitadel`.
No new GCP Secret Manager source is introduced.

The URL uses the Valkey protocol inside the workload; Istio ambient provides
inter-workload encryption and identity. The DENY policy rejects all source
principals except the login workload and this Valkey cluster. Network policies
admit HBONE and scope login data-port egress to the dedicated HAProxy pods. The
proxy uses the same dedicated service account as the cluster. There are no
namespace-wide plaintext client allowances.

The secret reference is optional at login pod startup so a missing OTP dependency
does not disable existing staff/social login. The application rejects email
sign-in when the URL is absent. Opt-in must wait until the secret, mesh connection,
password enforcement and cache readiness are verified.

## Release gates and ordering

1. Pass the operator and login PR checks and publish immutable image digests.
   Operator PR: `tesserix/tesserix-operators#27`; login PR: `tesserix/zitadel#7`.
2. Obtain approval for the named production rollout before merging/applying these
   GitOps changes. Targets are OpenBao's new reader policy/role, Zitadel's new
   secret reader, dedicated Valkey resources, login environment/image, and the
   compatible operator/CRD. Preserve Helivanta's migration and promotion hold.
3. Seed the new OpenBao path without displaying the value. Reconcile the reader
   policy/role and ESO resources; require the ExternalSecret to become Ready.
4. Reconcile the dedicated Valkey application. Verify three members, Sentinel
   quorum, writable primary, both proxies, unauthenticated rejection, login
   connectivity, and rejection from an unrelated service account. Confirm no
   secret or session data is emitted by diagnostics.
5. Deploy the compatible operator/CRD and login image, preserving existing
   broker social patches and nonnumeric consumer organization-scope parsing.
   Do not update the Zitadel broker API or Helivanta staff application image.
6. Enable only the explicitly selected test/tenant organization. Confirm the
   mailbox-verification link/code, sign-in OTP, native PKCE callback and product
   session with the authorized test mailbox. Confirm returning login, wrong and
   reused codes, explicit opt-out, and staff password/MFA/social regressions.
7. Close the tracking issue only after those live checks. A Ready claim, rendered
   chart, unit suite or isolated native integration test is not production proof.

Production rollout has not been performed. The operator shared-workflow pin and
unavailable base image pins have been corrected; all required checks must pass.
The live `kargo-zitadel-operator` ProjectConfig automatically promotes to `prod`,
so merging the operator release is itself a production rollout and requires the
same named approval. The deployment bundle now includes the canonical optional
email OTP CRD; finalize its matching operator image before promotion.
The login candidate is `feat-consumer-email-otp-e688e06` at digest
`sha256:856166971b3f157e61860778ab4ba1d76f52a21cde8466e1984aa8dbfb59d103`.
Operator PR #27 merged with rollout approval at `e9959df9def7bfe3a0cdcd76455b4c2462a5f0fa`.
Its published image is pinned to
`sha256:44c41e4f7355e5e45e3240031586d0624b7f31090fbd081bb71fb284a4c0e626`.
Verify the running operator matches it before test opt-in. The user selected an
isolated test organization; existing product claims remain unchanged.
