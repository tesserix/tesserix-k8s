# Analytics onboarding

Claims in `claims/` reconcile OpenPanel projects through its Manage API and
mirror each write client ID to `prod-openpanel-<claim>-client-id` in GCP Secret
Manager. Product charts can materialize that value through External Secrets.

The operator deliberately has no delete finalizer. Removing a claim or rolling
back this Argo CD application leaves the OpenPanel project and GCP secret in
place; cleanup requires a separately approved destructive operation.
