# Helivanta payments credential access

Helivanta's payments module owns provider accounts and payment intents. Release
[tesserix/helivanta#1435](https://github.com/tesserix/helivanta/pull/1435) seals
provider credentials with the Transit key `helivanta-payments-credentials`.
The server supplies a tenant/account derivation context for every operation.

The existing `helivanta-api-transit` Kubernetes role binds only service account
`helivanta-api` in namespace `helivanta`. Its policy grants `create, update` on
`transit/encrypt/helivanta-payments-credentials` and `update` on the corresponding
decrypt path. Existing staff and emergency grants remain scoped to their keys.
Key administration and export stay outside this role.

Apply the OpenBao bootstrap policy before promoting the application release.
Use Kargo's `kargo-helivanta/prod` stage and a verified freight commit whose API
and shell images are published. API promotion runs the existing PreSync
migration job. Follow the release approval requirements for database migrations.
Provider credentials continue to be entered through the authorized application;
GitOps stores the policy and service-account binding.

Provider calls use the API's existing HTTPS egress. Public webhook configuration
is optional: the poller provides confirmation until webhook ingress and
`PAYMENTS_WEBHOOK_BASE_URL` are configured. An unavailable OpenBao service causes
credential setup to fail closed with 503. Merchant QR enablement and live payment
acceptance require the merchant's provider configuration and separate functional
verification.

Validate the policy, role isolation, token lifetime and network boundary with:

```sh
uv run --with pytest --with pyyaml python -m pytest tests/test_helivanta_transit_access.py -q
helm lint charts/thirdparty/openbao --strict
```
