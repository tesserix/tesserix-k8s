# Helivanta Staff identity runtime

The API uses the existing dedicated `helivanta-onboarding-client` machine user
for protected ordinary Staff-account commands and organization-identity proof.
This does not use a login PAT, owner credential or platform-administrator role.
The identity owner remains responsible for native creation, invitation dispatch
and recipient verification/password setup.

`organizationIdentity.enabled` defaults to false. Enable only after the HMS
release includes client-secret support and the protected account routes. Set
`organizationIdentity.tokenProjectID` to the observed `onboarding-api` project ID
from its reconciled ZitadelProject claim. The audience is not the Helivanta login
project. A missing audience refuses Helm rendering.

The namespaced SecretStore authenticates as `helivanta-api` with the existing
`helivanta-onboarding-client-reader` OpenBao role. Its policy reads only
`kv/data/helivanta/prod/app/helivanta-onboarding-client`. ESO reads the canonical
operator-owned `value` property into a dedicated Kubernetes Secret. The API
mounts only `client-secret`, read-only with mode 0440; no identity credential is
exposed to the shell, Global API, migration job or application environment.

The identity SDK exchanges this credential for short-lived, audience-bound
access tokens. ESO refreshes every five minutes. The API loads its credential at
startup: an operator-authorized credential rotation requires the normal GitOps
rollout afterward; ESO refresh alone does not reload process memory. This change
does not rotate or replace credentials.

Promote the signed HMS image through the production release workflow and Kargo.
After its replicas are ready, enable the configuration in the owning Argo values
and promote the tested chart revision through Kargo. Verify SecretStore and
ExternalSecret conditions, Deployment readiness and authenticated Global API
account commands. A healthy pod or rendered chart alone does not prove account
creation or independently reviewed operating access. Disable the feature through
GitOps to stop new commands; never delete accounts or owner-ledger evidence as
rollback. No database migration or new standing infrastructure is introduced.
