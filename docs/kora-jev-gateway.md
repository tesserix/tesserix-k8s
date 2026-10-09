# Kora Jev gateway route

This change prepares a private typed-decision route; it does not activate Jev
in Kora user requests or clear `KORA_API_DEPLOY_HOLD`.

## Secret and ownership

OpenBao KV v2: `kora/app/kora-typesafe-api-key`, property `value`.
The only explicit production read grant is
`read-kora-agentgateway-system-production`. ESO creates
`agentgateway-system/kora-typesafe-credentials` with key `api-key`.
Kora API, mobile and agent pods do not receive this provider credential.
Do not place a key in Helm values, CI output, test fixtures or PR descriptions.

The active gateway resources are Registry-owned. The Helm templates are the
source for the generated `agentgateway-route-sync/files/platform-resources.json`
bundle and the tested Helm rollback path. The platform seed imports the bundle;
Registry reconciles the resources. Regenerate with:

```sh
python3 scripts/generate-agentgateway-platform-resources.py
python3 scripts/generate-agentgateway-platform-resources.py --check
```

The bundle gains exactly three resources: `HTTPRoute/kora-decide`,
`AgentgatewayBackend/kora-typesafe`, and
`AgentgatewayPolicy/kora-decide-traffic`. Its seed count becomes 30. Existing
resources retain their specs.

## Protocol and admission

`POST /v1/decisions` on the private Kora gateway requires the existing client
API key and Firebase end-user JWT. Workload admission remains enforced by
existing NetworkPolicy/Istio rules. The route accepts the logical model
`kora-decide`, caps the request at 16,000 bytes and replaces the provider model
with `jev-1.13.0`. The upstream is HTTPS `api.typesafe.ai/v1/systemone`.

Strip user/delegated identity headers and cookies before provider egress.
Backend authentication replaces the client credential with the OpenBao key.
This is a static JSON backend, not an OpenAI chat backend: no chat translation,
prompt optimization or generative-provider fallback is applied. Requests have
a 1.5-second deadline and the existing per-replica request-rate bound. Product
quota and provider-attempt accounting still belong in the consuming application.

## Rollout verification

- Require green rendered-manifest, Registry-bundle, OpenBao-scope and schema
  checks. Validate CEL/body translation with gateway version 1.4.1.
- Reconcile OpenBao policy and ExternalSecret before admitting the route.
- Require `SecretSynced`, accepted/resolved route status and healthy gateway.
- Exercise missing/wrong client key, missing/wrong user JWT, wrong method,
  oversized request and wrong model alias on the actual gateway.
- Run Kora `cmd/aidecide` with a valid test-account token against this route.
  The fixed eight-case corpus is synthetic; it is not a calibration dataset.
- Verify the provider key and user JWT never appear in telemetry. Do not infer
  zero retention from the API key; provider admission is required before real
  user content.

Rollback through GitOps: revert the resource bundle, templates and reader grant
together using the Registry-supported deletion/reconciliation path. Merely
omitting an imported Registry object must not be assumed to delete it. Keep
application callers disabled while rollback convergence is verified. Retain the
stored key unless its deletion/rotation is explicitly requested.
