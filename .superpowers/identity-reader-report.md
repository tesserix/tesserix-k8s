# Wiring console-identity-reader into tesserix-k8s

## Scope

Worktree: `.claude/worktrees/identity-reader`, branch `feat/console-identity-reader`.
No writes against live Zitadel or GCP were made. Chart, values and Python changes only.

## Changes

### 1. `charts/apps/console/templates/externalsecret.yaml`
Added a `ZITADEL_IDENTITY_READER_PAT` entry mapping to GCP secret
`prod-console-identity-reader-pat`, following the `ZITADEL_LOGIN_CLIENT_TOKEN`
pattern exactly (unconditional entry, not gated behind a values flag).

**ESO `data`-as-a-unit constraint**: the file's own comment says one
unresolvable `remoteRef` parks the whole ExternalSecret in `SecretSyncedError`
and stops `SESSION_ENCRYPT_KEY` from refreshing too — a silent login-loop risk.
I honoured this by only adding the entry unconditionally because the secret is
**already provisioned and verified** (version 1, enabled, 277 chars) — same
posture as `ZITADEL_LOGIN_CLIENT_TOKEN`. I did not gate it behind a values flag
like the Stripe keys, since there's no "may not exist yet" scenario here.

No Deployment change was needed: `envFrom: secretRef` already projects every
key in `console-secrets` into the container, confirmed by reading
`deployment.yaml`'s existing comment and by `helm template` showing the
unchanged single `envFrom` block.

### 2. `charts/apps/zitadel-bootstrap/values.yaml`
- Added `console-identity-reader` to `desired.machineUsers` (org TESSERIX,
  `ACCESS_TOKEN_TYPE_BEARER`, required `description` stating the purpose and
  scoping decision, referencing tesserix-home#211).
- Added new `desired.orgMemberships` list, seeded with
  `console-identity-reader` / TESSERIX / `[ORG_OWNER_VIEWER]`.

### 3. `charts/apps/zitadel-bootstrap/files/bootstrap.py`
Added `assert_org_memberships(org_memberships)` — a read-only check, not a
reconciler. For each declared `{org, login, roles}` it resolves the org and
user, calls `POST /management/v1/users/{userId}/memberships/_search` with
`x-zitadel-orgid` set (mandatory — the endpoint returns `{"result": []}`
rather than an error when the header is missing, which would otherwise be
indistinguishable from a genuinely revoked membership), matches the result by
`details.resourceOwner == org id`, and fails the run naming the login and org
if the membership is missing or roles differ.

Wired into `main()` right after `reconcile_instance_members`, before
`reconcile_default_org`, so a machine user created earlier in the same pass is
checkable immediately rather than on the next run.

Comment in the function and in `docs/zitadel.md` states the real reason this
asserts instead of reconciles: `POST /management/v1/orgs/members` (the write
path an org-scoped reconciler would suggest) returns
`{"code":5,"message":"Not Found"}` on this Zitadel v4.15.3, verified against
the live instance. Shipping a guessed write path would fail the job every 30
minutes with a 404 that names the wrong problem.

### 4. `docs/zitadel.md`
- Extended the "Branding, login policy and admins are reconciled" section with
  a paragraph on why org memberships are asserted, not reconciled.
- Added a `console-identity-reader` record under "What is not in git" →
  machine user credentials: userId, org, membership, PAT secret name and env
  var, verification results, and the scoping decision (no user-only reader
  role exists; `ORG_OWNER_VIEWER` on TESSERIX chosen over instance-wide
  `IAM_OWNER_VIEWER` because the latter would read every org including
  ZITADEL's own console config).

## Tests added (`bootstrap_test.py`, class `OrgMembershipTest`, 8 tests)

1. `test_passes_when_roles_match`
2. `test_is_a_read_only_check` — no PUT/DELETE/write POST calls
3. `test_fails_naming_login_and_org_when_membership_is_genuinely_absent` — the
   core property: empty result list must fail, not pass vacuously
4. `test_fails_when_membership_exists_in_a_different_org` — a result list from
   a different `resourceOwner` must not count as a match
5. `test_fails_when_roles_have_drifted`
6. `test_fails_when_user_does_not_exist` — also asserts no membership-search
   call is made with a bogus/missing user id
7. `test_always_sends_the_org_id_header` — pins the header on every call
8. `test_missing_org_fails_closed`

Plus `MainTest.test_fails_when_a_declared_org_membership_is_missing`, proving
`main()` actually invokes `assert_org_memberships` and not just that the
function works standalone.

## Mutations performed (each restored after observing the expected failure)

1. Dropped the `resourceOwner` match, matching on `next(iter(results))` →
   `test_fails_when_membership_exists_in_a_different_org` failed with
   `SystemExit not raised`. Restored.
2. Dropped the `headers=scope` kwarg on the search call →
   `test_always_sends_the_org_id_header` failed (`[None] != ['org-tesserix']`).
   Restored.
3. Removed the roles-drift check entirely →
   `test_fails_when_roles_have_drifted` failed (`SystemExit not raised`).
   Restored.
4. Replaced the "no such user" guard with a fallback `"MISSING"` user id.
   Initially the weakened version of `test_fails_when_user_does_not_exist`
   passed for the wrong reason (Recorder's default `(200, b"{}")` response for
   the unregistered path still produced an empty result → still failed, just
   not via the intended guard). Strengthened the test to assert the exact
   message ("no such user") and that no membership-search call was made; the
   same mutation then failed it correctly. Restored.
5. Removed the `assert_org_memberships(...)` call from `main()` entirely →
   the new `MainTest` case failed with `SystemExit not raised`, proving the
   wiring is actually exercised. Restored.

## Verification

- `python3 charts/apps/zitadel-bootstrap/files/bootstrap_test.py` — 107 tests,
  all pass, unmodified existing tests untouched.
- `helm template charts/apps/zitadel-bootstrap` — renders; rendered
  `desired.json` includes the new machine user and `orgMemberships`.
- `helm template charts/apps/console` — renders (required `helm dependency
  build` first for the `common` chart, unrelated to this change); rendered
  output includes `ZITADEL_IDENTITY_READER_PAT` /
  `prod-console-identity-reader-pat`, and the Deployment's `envFrom` block is
  unchanged (single `secretRef`, no new `env` entries needed).

## Concerns

- The org-membership grant itself (`ORG_OWNER_VIEWER` for
  `console-identity-reader`) is a manual, one-time console action per
  docs/zitadel.md and this task's constraints — until it's done, the next
  `zitadel-bootstrap` run will fail naming
  `console-identity-reader`/TESSERIX. That's intentional (fail-closed,
  matches the task's "assert, don't reconcile" instruction) but worth flagging
  since it will red the CronJob until performed.
- No write-path test exists for org memberships, by design — there's nothing
  safe to write yet on this Zitadel version.
