# Zitadel onboarding operator

This operator reconciles declarative Zitadel project and public OIDC
application claims. It reads its machine key from External Secrets and writes
only status identifiers back to claims; no client secret is created or stored.

Claims live in `k8s/claims/identity/zitadel/` and are reconciled by the
`zitadel-claims` Argo CD Application into `identity-operator`, the namespace
watched by this operator.

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

`k8s/claims/identity/zitadel/homechef.yaml` creates the HomeChef project only.
Applications are deferred until the migration has approved redirect URI and
audience contracts, so the existing GIP users and clients remain unchanged.
