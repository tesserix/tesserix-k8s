# Secrets console cutover — chart PR report

Branch: `feat/secrets-cutover`. Worktree only, nothing pushed.

## Deviation from the original brief (must-read)

The brief's item 6 asked to narrow `secret-service-api`'s AuthorizationPolicy to
the console's principal `cluster.local/ns/tesserix/sa/console`. **This was not
done.** The coordinator verified live cluster labels mid-task:

```
tesserix         istio.io/dataplane-mode=<none>   istio-injection=disabled   pod containers: [console]
secret-service   istio.io/dataplane-mode=ambient                             pod containers: [api]
```

`tesserix` is not in the Istio mesh (no sidecar, no ambient label), so the
console presents no SPIFFE identity. A principal rule can never match an
unmeshed workload — writing one would have denied the console outright and
turned this cutover into an outage. Per the coordinator's ruling:

- The AuthorizationPolicy admits `tesserix` **by namespace**, not principal,
  alongside the existing `devai` principal rule (which is kept as-is).
  `istio-ingress`/`istio-system` are dropped (correct now the VirtualService
  is gone); `secret-service` and `monitoring` stay.
- The comment says explicitly that this is a namespace check, not an identity
  check, and that it should tighten to a principal rule once `tesserix` joins
  the mesh — it does **not** say "genuine second gate" (§7's wording is wrong
  for an unmeshed client).
- Two additive NetworkPolicy changes were added, not in the original file
  list, because without them the console cannot reach the API at L3/L4
  regardless of what the AuthorizationPolicy allows:
  - `charts/apps/secret-service/templates/network-policies.yaml`: new
    `allow-ingress-console` policy, ingress from namespace `tesserix` to the
    api pod on `.Values.api.port`. Comment notes `allow-hbone-15008` does
    **not** cover this — that's HBONE-tunnelled ambient-mesh traffic, and an
    unmeshed client sends plain TCP.
  - `charts/apps/console/templates/network-policy.yaml`: new egress rule to
    namespace `secret-service` on port 8080.
- **Follow-up filed, not fixed here**: the right end state is `tesserix`
  joining the ambient mesh and the policy tightening to the console's
  principal, per what §7 actually wants. That's a change to how the console
  is deployed, not a chart tweak — please file it.

## Files changed and why

**`charts/apps/secret-service/values.yaml`**
- `api.image.tag` → `main-4a2c28f`.
- Removed `host`, `adminEmails` (and its now-false "this line is the actual
  access-control decision" comment — the decision moved to Zitadel),
  `sessionTTL`, `google:` block, `web:` block.
- Removed `externalSecret.sessionKeySecret`, `.googleClientIDSecret`,
  `.googleClientSecret`; kept `githubTokenSecret`.
- Added `zitadel: {issuer, projectId, consoleClientID}` with the three
  supplied values, with a comment on why the same operator token works
  (same Zitadel project as platform-api).
- Kept `workloadSecretBroker` in full — feeds the Istio rule and NetworkPolicy
  even though its env vars are gone (see below).
- Left `istio.gateways` in place — unused now that the VirtualService is
  gone, but not on the deletion list and `istio.enabled` still gates the
  AuthorizationPolicy template; removing it would be a drive-by.

**`charts/apps/secret-service/templates/deployment-api.yaml`**
- Removed `APP_BASE_URL`, `ALLOWED_ORIGINS`, `SESSION_TTL`, `ADMIN_EMAILS`,
  and all five `WORKLOAD_SECRET_*` vars — `main-4a2c28f`'s config.go reads
  none of them.
- Added `ZITADEL_ISSUER`, `ZITADEL_PROJECT_ID`, `ZITADEL_CONSOLE_CLIENT_ID`.
- Kept `OPENBAO_K8S_ROLE`/`OPENBAO_K8S_MOUNT`.
- Comment states the real reason `workloadSecretBroker`'s env vars go while
  its NetworkPolicy/Istio rule stay: the binary doesn't read them, but the
  integration is "configured but not built" (design §8) and those two
  resources are what keeps that door open.

**`charts/apps/secret-service/templates/externalsecret.yaml`** — removed
`SESSION_KEY`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`; kept `GITHUB_TOKEN`.

**Deleted `charts/apps/secret-service/templates/virtualservice.yaml`** —
`secret-service.tesserix.app` stops resolving.

**Deleted the web workload** — `templates/deployment-web.yaml` removed;
`service.yaml`, `pdb.yaml`, `serviceaccount.yaml` rewritten to drop the web
Service/PDB/ServiceAccount (api-only now, single resource per file, no `---`
separators left dangling).

**`charts/apps/secret-service/templates/authorization-policy.yaml`** —
rewritten to a single AuthorizationPolicy (web's deleted): namespace-based
admission for `["secret-service", "monitoring", "tesserix"]` plus the kept
`devai` principal rule. Header comment rewritten per the ruling above — states
this is a namespace check standing in for an identity check until `tesserix`
joins the mesh, and does not claim it's "a genuine second gate."

**`charts/apps/secret-service/templates/network-policies.yaml`** — added
`allow-ingress-console` (ingress from `tesserix` on `api.port`), with a
comment distinguishing it from `allow-hbone-15008` (plain TCP vs.
HBONE-tunnelled ambient traffic — flagged so nobody "simplifies" the two
together later).

**`charts/apps/console/values.yaml`** — added `SECRETS_API_ORIGIN:
"http://secret-service-api.secret-service.svc.cluster.local:8080"`.
Derived by reading `charts/apps/secret-service/templates/service.yaml`
(Service `secret-service-api`, port `.Values.api.port` = `8080`) and
following the `PLATFORM_API_ORIGIN` pattern in the same console values file
(`http://platform-api.tesserix.svc.cluster.local`, no port — platform-api's
Service listens on 80, confirmed in `charts/apps/platform-api/values.yaml`).
secret-service's Service does not listen on 80, so the port is explicit here,
unlike `PLATFORM_API_ORIGIN`/`WEB_INTERNAL_ORIGIN`.

**`charts/apps/console/templates/network-policy.yaml`** — added an egress
rule to namespace `secret-service` on port 8080 (see deviation above).

**Chart.yaml bumps** — `secret-service` `0.3.7` → `0.3.8`; `console` `0.1.18`
→ `0.1.19`.

**`tests/test_devai_gateway_and_secrets.py`** — updated
`test_secret_service_broker_uses_tokenreview_and_fixed_openbao_scope`, which
asserted `WORKLOAD_SECRET_BROKER_ENABLED`/`_NAMESPACE`/`_APP` were set on the
deployment. That's now false by design (the binary doesn't read them), so the
assertions were flipped to `assertNotIn` with a comment explaining why, and
why the rest of the test (ClusterRole, OpenBao policy, NetworkPolicy checks
downstream of `workloadSecretBroker` values) is untouched and still holds.

## Where I followed the design doc over the brief

- **The AuthorizationPolicy narrowing (brief item 6)** — not done; see
  Deviation above. The design doc's own §7 assumed a meshed client and was
  itself wrong here; the coordinator's live-cluster check is authoritative.
- Otherwise the brief and the design doc (§2, §7, §9) agreed; no other
  conflicts found.

## What a revert restores

Reverting this PR restores: the VirtualService and public host, the web
workload (Deployment/Service/PDB/AuthorizationPolicy/ServiceAccount), the
`adminEmails`/session/Google config and their env vars, the gateway-scoped
AuthorizationPolicy, and pins the image back to `main-84ace73`. The two added
NetworkPolicy allows are additive-only, so reverting them is also clean — no
resource this PR deletes is depended on by anything this PR doesn't also
restore.

## Commands run

- `helm lint charts/apps/secret-service` → 0 failed (1 info: icon recommended).
- `helm lint charts/apps/console` → 0 failed (missing-dependency warning
  resolved by `helm dependency build charts/apps/console`, which vendors the
  gitignored `common-1.0.0.tgz`; not committed).
- `helm template test charts/apps/secret-service` → renders cleanly, single
  Service/PDB/ServiceAccount/AuthorizationPolicy per file, correct env vars.
- `helm template test charts/apps/console` → renders cleanly,
  `SECRETS_API_ORIGIN` present with the derived value.
- `python3 charts/apps/zitadel-bootstrap/files/bootstrap_test.py` → 98 passed.
- `python3 -m pytest tests/test_devai_gateway_and_secrets.py
  tests/test_secret_manager_write_blind.py -q` → 2 failed initially:
  - `test_gateway_routes_are_provider_specific_and_private` — **pre-existing,
    unrelated**. Confirmed by `git stash` and re-running against
    unmodified `main`: same failure (`devai-sandbox` principal missing from
    an unrelated `ai-gateway` AuthorizationPolicy expectation). Not touched.
  - `test_secret_service_broker_uses_tokenreview_and_fixed_openbao_scope` —
    caused by this change; fixed as described above. Re-ran after the fix:
    7 passed.

## Concerns for follow-up (not fixed here, out of scope)

1. **Mesh gap (main deviation, filed per coordinator instruction)** — tighten
   the AuthorizationPolicy to the console's principal once `tesserix` joins
   the ambient mesh; today it's a namespace check.

## Addendum: removed the orphaned istio-auth-policies entry (second round)

The coordinator asked for one more change after reviewing the first report:
remove the `secret-service` entry from
`argocd/prod/infrastructure/istio-auth-policies.yaml`'s inline
`spec.source.helm.values.frontendApps` list, rather than leaving it as a
flagged follow-up. Reasons given, all valid:

1. Its comment claims *"the API enforces the two-address allowlist on every
   request"* — false the moment this PR merges, since `ADMIN_EMAILS` and the
   allowlist are deleted. A stale comment claiming email-allowlist protection
   when the real protection is Zitadel capabilities is the exact
   misattribution defect this estate keeps hitting.
2. `label: secret-service-web` selects a workload this PR deletes — an edge
   ALLOW for a pod that no longer exists.
3. `hosts: secret-service.tesserix.app` stops resolving once the
   VirtualService is gone.

**What was removed** — the 10-line block at the (original) lines 266-275 of
`argocd/prod/infrastructure/istio-auth-policies.yaml`:

```yaml
# secret-service — the OpenBao admin console. No `namespace`: the
# console is two workloads (UI + API) and this template's per-app
# policy selects a single label, so the pod-level ALLOWs live in
# charts/apps/secret-service instead. Unauthenticated at the edge so
# the OIDC redirect is reachable; the API enforces the two-address
# allowlist on every request.
- name: secret-service
  label: secret-service-web
  hosts:
    - "secret-service.tesserix.app"
```

Edited directly in the committed Application manifest (not a chart file) —
per the coordinator's note, this Application's inline `spec.source.helm.values`
block is genuinely respected by ArgoCD (unlike a Helm parameter), so no
`parameters:` entry was added or needed.

**Blast-radius check, done before editing:** `secret-service` was one item in
`.Values.frontendApps`, a list consumed by
`charts/infrastructure/istio-auth-policies/templates/frontend-allow.yaml`.
That template emits, per gateway in `.Values.ingressGateways`, one aggregate
`AuthorizationPolicy` (`allow-frontend-apps-public<gateway>`) with one
`rules[].to.operation.hosts` block per app that declares `hosts`, plus a
separate per-namespace pod-level policy only for apps that declare a
`namespace` field. `secret-service`'s entry had no `namespace` (per its own
comment — the pod-level ALLOWs live in the secret-service chart instead), so
removing it can only ever drop its own host-rule blocks from the aggregate
gateway policies; it shares no `namespace`, no `label`, and no list index
dependency with any other entry (`gameverse`, `opencost`, etc. are independent
map entries in the same list).

**Rendered-diff proof:**
- Extracted the Application's inline `spec.source.helm.values` block to a
  temp values file with a small Python/yaml script (the string is not valid
  standalone YAML on its own without extraction from the Application
  wrapper).
- `helm template istio-auth-policies charts/infrastructure/istio-auth-policies
  -f <extracted-values>` before and after the edit, both exit 0.
- `diff before.yaml after.yaml` — the *only* difference in the entire
  rendered output (2799 lines) is the disappearance of two identical blocks,
  one per ingress gateway:
  ```
  1692,1695d1691
  <     - to:
  <         - operation:
  <             hosts:
  <               - "secret-service.tesserix.app"
  1921,1924d1916
  <     - to:
  <         - operation:
  <             hosts:
  <               - "secret-service.tesserix.app"
  ```
  Every other app's rendered policy (`gameverse`, `opencost`, `falco`,
  `fe3dr`, etc.) is byte-identical before and after. Confirmed: this change
  touches only `secret-service`.

Committed as `fix(istio-auth-policies): drop the orphaned secret-service edge
ALLOW` on `feat/secrets-cutover`. Not pushed.
