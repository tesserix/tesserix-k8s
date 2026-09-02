# Zitadel onboarding operator

This operator reconciles declarative Zitadel project and public OIDC
application claims. It reads its machine key from External Secrets and writes
only status identifiers back to claims; no client secret is created or stored.

## Why public applications have no secret

The operator creates `user_agent` and `native` applications as **public OIDC
clients**. A browser SPA or installed mobile app cannot keep a client secret:
any value bundled into JavaScript, an APK, or an IPA can be extracted and is
therefore public. Creating a Secret Manager entry for such a value would give a
false sense of security without protecting the client.

Their client IDs are deliberately non-secret identifiers. Authentication is
protected by Authorization Code with PKCE, exact registered redirect URIs, and
server-side validation of the token signature, issuer, audience, expiry, and
algorithm. The authorization code is bound to the client-generated PKCE
verifier, so an intercepted code is not usable by an attacker without that
verifier. Public clients must never use a wildcard redirect URI or embed a
machine key, client secret, or service-account credential.

Use a separate confidential client only when a server can keep credentials out
of user-controlled software (for example, a backend-to-backend integration or
a BFF token exchange). That is a different claim contract: its generated
credential must be handed off directly to GCP Secret Manager and injected with
External Secrets, never committed to Git or written into claim status. The
current public-client operator contract intentionally does not create that
kind of credential.

Claims live in `k8s/operators/zitadel/claims/`. The `zitadel-operator` Argo CD
Application deploys both the controller and its claims into `identity-operator`,
the namespace watched by this operator.

## Add a product

1. Copy `claim-template.yaml` to `<product>.yaml` in the claims directory.
2. Use the exact Zitadel organization name and a stable lower-kebab-case claim
   name. Add the file to that directory's `kustomization.yaml`.
3. For an application claim, use PKCE public OIDC only and list every exact
   HTTPS or native redirect URI. Do not use wildcard, loopback production, or
   unverified redirect URIs.
4. Commit the claim to `tesserix-k8s`; Argo CD applies it. Confirm the claim's
   `Ready=True` condition and recorded ID before wiring any product runtime to
   the new project.

Deletion of a claim does not delete the remote Zitadel project or application.
That is deliberate: remote identity resources need an explicit, audited
decommission workflow.

## Initial HomeChef claim

`k8s/operators/zitadel/claims/homechef.yaml` creates the HomeChef project and
its approved public OIDC applications.
