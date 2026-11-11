# Helivanta onboarding email

Helivanta onboarding uses a product-scoped Resend sending credential. Native
Zitadel remains the identity and verification-code authority. Its instance-wide
SMTP configuration also serves other products and must not be replaced with this
credential.

## Credential custody

The exact KV v2 path is
`kv/helivanta/prod/app/helivanta-onboarding-resend-api-key`, property `value`.
Never place the value in Git, Helm values, command arguments, logs or browser
configuration. A sending-only Resend key is sufficient; inability to enumerate
domains is expected with that permission.

The `helivanta-onboarding-email-writer` OpenBao Kubernetes role can create, read
and update only this key. The separate reader can only read this key. Both roles
are bound to matching dedicated service accounts in `onboarding`, require the
`vault` audience and have a five-minute maximum token lifetime. Neither account
automounts a token or runs the application workload. The writer also permits
revoking its own token. Kubernetes TokenRequest access is the operational access
boundary; no recovery/root credential is needed.

After GitOps reconciliation, use a short-lived TokenRequest, authenticate to
OpenBao, and write the credential using stdin and KV v2 compare-and-set. Creation
uses CAS 0. An existing different value requires explicit rotation approval;
retain previous KV versions. Verify equality privately and revoke the task token.
Report only the path, version and success. Retain the supplied source until
storage and the runtime reader have been verified.

## Activation order

This access change creates no ExternalSecret and activates no outbound mail.
It is safe to reconcile before the key exists. Credential storage, namespace-
scoped ESO reader, read-only runtime file mount, operator support for native
code return, and onboarding delivery integration must be verified before mail
activation. API keys and native codes must never be returned by public APIs.

The sender domain must be verified in Resend. Confirm the sender because the
request named `helivanta.com` while the supplied domain evidence showed
`helivanta.app`. A provider message acceptance is not proof of inbox delivery.
Existing native users authenticate through the existing-account flow and must
not receive a privileged password reset or have their original account replaced.

## Validation and recovery

`tests/test_helivanta_onboarding_email_access.py` renders the real Helm resources
and verifies exact-path policies, namespace/audience restrictions, short token
lifetimes, account isolation and inactive delivery. Lint both affected charts.
Removing the access resources through GitOps removes future credential access;
already issued tokens expire within five minutes. It does not delete KV data or
change the shared SMTP provider. No new workloads or persistent storage are added.
