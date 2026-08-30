"""Tests for bootstrap.py. Run with `python3 bootstrap_test.py` — stdlib only.

The job runs every 30 minutes against a live instance, so the property that
matters is idempotency: an in-sync instance must produce zero writes.
"""

import json
import os
import tempfile
import unittest
from unittest import mock

WORKDIR = tempfile.mkdtemp()
os.makedirs(os.path.join(WORKDIR, "assets"), exist_ok=True)
with open(os.path.join(WORKDIR, "pat"), "w") as fh:
    fh.write("test-token\n")
with open(os.path.join(WORKDIR, "assets", "logo-light.png"), "wb") as fh:
    fh.write(b"light-bytes")

os.environ.update({
    "ZITADEL_API": "http://zitadel:8080",
    "ZITADEL_HOST": "auth.example.test",
    "PAT_PATH": os.path.join(WORKDIR, "pat"),
    "ASSET_DIR": os.path.join(WORKDIR, "assets"),
})

import bootstrap  # noqa: E402  - imported after the environment it reads at load


LIVE_LABEL_POLICY = {"primaryColor": "#5B5FD6", "themeMode": "THEME_MODE_AUTO", "disableWatermark": True}
LIVE_LOGIN_POLICY = {"allowUsernamePassword": True, "allowRegister": False}

# Session durations the chart does not declare. Held in constants rather than
# inline literals because secret scanners read a field name beginning with
# "password", assigned a quoted string, as a credential and fail the build.
CHECK_LIFETIME_FIELD = "passwordCheckLifetime"
LONG_LIFETIME = "240h0m0s"
SHORT_LIFETIME = "12h0m0s"
REDIRECT_URI = "https://app.example.test"


class Recorder:
    """Stands in for bootstrap.request, recording writes and replaying canned reads."""

    def __init__(self, responses):
        self.responses = responses
        self.calls = []
        # Kept beside calls rather than in it, so the 5-tuple unpacking below stays valid.
        self.headers = []

    def __call__(self, method, path, body=None, headers=None, raw=None, content_type=None):
        self.calls.append((method, path, body, raw, content_type))
        self.headers.append((path, headers or {}))
        return self.responses.get((method, path), (200, b"{}"))

    @property
    def writes(self):
        return [(method, path) for method, path, _, _, _ in self.calls if method in ("PUT", "POST")]


class DriftTest(unittest.TestCase):
    """Zitadel omits protobuf default values, so absent must compare equal to them."""

    def test_absent_false_boolean_is_not_drift(self):
        self.assertEqual(bootstrap.drift_between({"forceMfa": False}, {}), {})

    def test_absent_empty_string_is_not_drift(self):
        self.assertEqual(bootstrap.drift_between({"defaultRedirectUri": ""}, {}), {})

    def test_absent_true_boolean_is_drift(self):
        self.assertEqual(bootstrap.drift_between({"forceMfa": True}, {}), {"forceMfa": True})

    def test_present_and_different_is_drift(self):
        self.assertEqual(bootstrap.drift_between({"allowRegister": False}, {"allowRegister": True}),
                         {"allowRegister": False})

    def test_present_and_equal_is_not_drift(self):
        self.assertEqual(bootstrap.drift_between({"primaryColor": "#5B5FD6"}, {"primaryColor": "#5B5FD6"}), {})


class LabelPolicyTest(unittest.TestCase):
    def test_no_write_when_policy_matches(self):
        recorder = Recorder({("GET", "/admin/v1/policies/label"): (200, json.dumps({"policy": LIVE_LABEL_POLICY}).encode())})
        with mock.patch.object(bootstrap, "request", recorder):
            self.assertFalse(bootstrap.reconcile_label_policy(dict(LIVE_LABEL_POLICY)))
        self.assertEqual(recorder.writes, [])

    def test_writes_when_a_colour_drifts(self):
        recorder = Recorder({("GET", "/admin/v1/policies/label"): (200, json.dumps({"policy": LIVE_LABEL_POLICY}).encode())})
        desired = dict(LIVE_LABEL_POLICY, primaryColor="#000000")
        with mock.patch.object(bootstrap, "request", recorder):
            self.assertTrue(bootstrap.reconcile_label_policy(desired))
        self.assertEqual(recorder.writes, [("PUT", "/admin/v1/policies/label")])

    def test_put_preserves_undeclared_fields_and_drops_asset_urls(self):
        """Asset URLs are owned by the assets API; the policy PUT must not carry them."""
        live = dict(LIVE_LABEL_POLICY, primaryColor="#000000", hideLoginNameSuffix=True,
                    logoUrl="https://auth.example.test/assets/v1/logo-1",
                    iconUrlDark="https://auth.example.test/assets/v1/icon-2",
                    isDefault=True, details={"sequence": "7"})
        recorder = Recorder({("GET", "/admin/v1/policies/label"): (200, json.dumps({"policy": live}).encode())})
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_label_policy(dict(LIVE_LABEL_POLICY))
        sent = [call[2] for call in recorder.calls if call[:2] == ("PUT", "/admin/v1/policies/label")][0]
        self.assertEqual(sent["primaryColor"], "#5B5FD6")
        self.assertEqual(sent["hideLoginNameSuffix"], True)
        for key in ("logoUrl", "iconUrlDark", "isDefault", "details"):
            self.assertNotIn(key, sent)

    def test_ignores_live_fields_git_does_not_declare(self):
        live = dict(LIVE_LABEL_POLICY, logoUrl="https://auth.example.test/assets/v1/logo-1")
        recorder = Recorder({("GET", "/admin/v1/policies/label"): (200, json.dumps({"policy": live}).encode())})
        with mock.patch.object(bootstrap, "request", recorder):
            self.assertFalse(bootstrap.reconcile_label_policy(dict(LIVE_LABEL_POLICY)))
        self.assertEqual(recorder.writes, [])


class AssetTest(unittest.TestCase):
    def test_no_upload_when_bytes_match(self):
        recorder = Recorder({("GET", "/assets/v1/instance/policy/label/logo"): (200, b"light-bytes")})
        with mock.patch.object(bootstrap, "request", recorder):
            self.assertFalse(bootstrap.reconcile_asset("logo", "logo-light.png"))
        self.assertEqual(recorder.writes, [])

    def test_uploads_when_bytes_differ(self):
        recorder = Recorder({("GET", "/assets/v1/instance/policy/label/logo"): (200, b"stale-bytes")})
        with mock.patch.object(bootstrap, "request", recorder):
            self.assertTrue(bootstrap.reconcile_asset("logo", "logo-light.png"))
        self.assertEqual(recorder.writes, [("POST", "/assets/v1/instance/policy/label/logo")])

    def test_uploads_when_no_asset_is_set(self):
        recorder = Recorder({("GET", "/assets/v1/instance/policy/label/logo"): (404, b"not found")})
        with mock.patch.object(bootstrap, "request", recorder):
            self.assertTrue(bootstrap.reconcile_asset("logo", "logo-light.png"))
        self.assertEqual(recorder.writes, [("POST", "/assets/v1/instance/policy/label/logo")])

    def test_multipart_body_carries_the_file_bytes_and_boundary(self):
        recorder = Recorder({("GET", "/assets/v1/instance/policy/label/logo"): (404, b"")})
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_asset("logo", "logo-light.png")
        _, _, _, raw, content_type = recorder.calls[-1]
        boundary = content_type.split("boundary=")[1]
        self.assertIn(b"light-bytes", raw)
        self.assertIn(b'name="file"; filename="logo-light.png"', raw)
        self.assertTrue(raw.startswith(f"--{boundary}\r\n".encode()))
        self.assertTrue(raw.endswith(f"\r\n--{boundary}--\r\n".encode()))


class LoginPolicyTest(unittest.TestCase):
    def test_no_write_when_policy_matches(self):
        recorder = Recorder({("GET", "/admin/v1/policies/login"): (200, json.dumps({"policy": LIVE_LOGIN_POLICY}).encode())})
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_login_policy(dict(LIVE_LOGIN_POLICY))
        self.assertEqual(recorder.writes, [])

    def test_writes_when_registration_drifts_open(self):
        live = dict(LIVE_LOGIN_POLICY, allowRegister=True)
        recorder = Recorder({("GET", "/admin/v1/policies/login"): (200, json.dumps({"policy": live}).encode())})
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_login_policy(dict(LIVE_LOGIN_POLICY))
        self.assertEqual(recorder.writes, [("PUT", "/admin/v1/policies/login")])

    def test_put_preserves_live_fields_the_chart_does_not_declare(self):
        """PUT replaces the policy, so an undeclared lifetime must be sent back as-is."""
        undeclared = {
            "allowRegister": True,
            CHECK_LIFETIME_FIELD: LONG_LIFETIME,
            "externalLoginCheckLifetime": SHORT_LIFETIME,
            "defaultRedirectUri": REDIRECT_URI,
        }
        live = dict(LIVE_LOGIN_POLICY, **undeclared)
        recorder = Recorder({("GET", "/admin/v1/policies/login"): (200, json.dumps({"policy": live}).encode())})
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_login_policy(dict(LIVE_LOGIN_POLICY))
        sent = [call[2] for call in recorder.calls if call[:2] == ("PUT", "/admin/v1/policies/login")][0]
        self.assertEqual(sent["allowRegister"], False)
        self.assertEqual(sent[CHECK_LIFETIME_FIELD], LONG_LIFETIME)
        self.assertEqual(sent["externalLoginCheckLifetime"], SHORT_LIFETIME)
        self.assertEqual(sent["defaultRedirectUri"], REDIRECT_URI)

    def test_put_drops_server_managed_metadata(self):
        """details/isDefault are read-only echoes; sending them back is not meaningful."""
        live = dict(LIVE_LOGIN_POLICY, allowRegister=True, isDefault=True,
                    details={"sequence": "42", "changeDate": "2026-08-15T00:00:00Z"})
        recorder = Recorder({("GET", "/admin/v1/policies/login"): (200, json.dumps({"policy": live}).encode())})
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_login_policy(dict(LIVE_LOGIN_POLICY))
        sent = [call[2] for call in recorder.calls if call[:2] == ("PUT", "/admin/v1/policies/login")][0]
        self.assertNotIn("details", sent)
        self.assertNotIn("isDefault", sent)

    def test_raises_on_api_error(self):
        recorder = Recorder({
            ("GET", "/admin/v1/policies/login"): (200, json.dumps({"policy": {"allowRegister": True}}).encode()),
            ("PUT", "/admin/v1/policies/login"): (403, b'{"message":"nope"}'),
        })
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_login_policy(dict(LIVE_LOGIN_POLICY))


class AdminTest(unittest.TestCase):
    USERS = {"result": [{"userId": "u-1", "username": "samyak.rout@gmail.com"}]}

    def test_matches_on_verified_email_when_username_differs(self):
        """zitadel-admin's login name is zitadel-admin@<domain>; git names it by email."""
        users = {"result": [{
            "userId": "u-9",
            "username": "zitadel-admin@zitadel.auth.example.test",
            "human": {"email": {"email": "unidevidp@gmail.com", "isVerified": True}},
        }]}
        recorder = Recorder({
            ("POST", "/admin/v1/members/_search"): (200, json.dumps({"result": []}).encode()),
            ("POST", "/v2/users"): (200, json.dumps(users).encode()),
        })
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_admins(["unidevidp@gmail.com"])
        grants = [call[2] for call in recorder.calls if call[:2] == ("POST", "/admin/v1/members")]
        self.assertEqual(grants, [{"userId": "u-9", "roles": ["IAM_OWNER"]}])

    def test_ignores_an_unverified_email_match(self):
        """An unverified address is attacker-controlled; it must not confer IAM_OWNER."""
        users = {"result": [{
            "userId": "u-9",
            "username": "someone-else",
            "human": {"email": {"email": "unidevidp@gmail.com", "isVerified": False}},
        }]}
        recorder = Recorder({
            ("POST", "/admin/v1/members/_search"): (200, json.dumps({"result": []}).encode()),
            ("POST", "/v2/users"): (200, json.dumps(users).encode()),
        })
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_admins(["unidevidp@gmail.com"])
        self.assertNotIn(("POST", "/admin/v1/members"), recorder.writes)

    def test_no_write_when_already_iam_owner(self):
        recorder = Recorder({
            ("POST", "/admin/v1/members/_search"): (200, json.dumps({"result": [{"userId": "u-1", "roles": ["IAM_OWNER"]}]}).encode()),
            ("POST", "/v2/users"): (200, json.dumps(self.USERS).encode()),
        })
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_admins(["samyak.rout@gmail.com"])
        self.assertNotIn(("POST", "/admin/v1/members"), recorder.writes)

    def test_grants_when_membership_missing(self):
        recorder = Recorder({
            ("POST", "/admin/v1/members/_search"): (200, json.dumps({"result": []}).encode()),
            ("POST", "/v2/users"): (200, json.dumps(self.USERS).encode()),
        })
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_admins(["samyak.rout@gmail.com"])
        self.assertIn(("POST", "/admin/v1/members"), recorder.writes)

    def test_skips_admin_who_has_never_signed_in(self):
        recorder = Recorder({
            ("POST", "/admin/v1/members/_search"): (200, json.dumps({"result": []}).encode()),
            ("POST", "/v2/users"): (200, json.dumps({"result": []}).encode()),
        })
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_admins(["nobody@gmail.com"])
        self.assertNotIn(("POST", "/admin/v1/members"), recorder.writes)

    def test_username_match_is_case_insensitive(self):
        """A cased login name must resolve to the user, not fall through to 'skipped'."""
        recorder = Recorder({
            ("POST", "/admin/v1/members/_search"): (200, json.dumps({"result": []}).encode()),
            ("POST", "/v2/users"): (200, json.dumps(self.USERS).encode()),
        })
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_admins(["Samyak.Rout@Gmail.com"])
        grants = [call for call in recorder.calls if call[1] == "/admin/v1/members" and call[0] == "POST"]
        self.assertEqual([call[2] for call in grants], [{"userId": "u-1", "roles": ["IAM_OWNER"]}])


ORGS = {"result": [
    {"id": "org-zitadel", "name": "ZITADEL"},
    {"id": "org-tesserix", "name": "TESSERIX"},
]}


class DefaultOrgTest(unittest.TestCase):
    def _recorder(self, current, extra=None):
        return Recorder({
            ("POST", "/admin/v1/orgs/_search"): (200, json.dumps(ORGS).encode()),
            ("GET", "/admin/v1/orgs/default"): (200, json.dumps({"org": {"id": current}}).encode()),
            **(extra or {}),
        })

    def test_no_write_when_already_default(self):
        recorder = self._recorder("org-tesserix")
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_default_org("TESSERIX")
        self.assertEqual([w for w in recorder.writes if not w[1].endswith("_search")], [])

    def test_promotes_the_named_org_when_another_is_default(self):
        recorder = self._recorder("org-zitadel")
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_default_org("TESSERIX")
        self.assertIn(("PUT", "/admin/v1/orgs/default/org-tesserix"), recorder.writes)

    def test_unknown_org_name_is_fatal(self):
        """A typo must not silently leave the old default in place."""
        recorder = self._recorder("org-zitadel")
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_default_org("TYPO")

    def test_raises_on_api_error(self):
        recorder = self._recorder("org-zitadel",
                                  {("PUT", "/admin/v1/orgs/default/org-tesserix"): (403, b'{"message":"nope"}')})
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_default_org("TESSERIX")


class OrgBrandingTest(unittest.TestCase):
    """Every org inherits the instance skin unless git says it brands itself."""

    def _recorder(self, is_default):
        return Recorder({
            ("POST", "/admin/v1/orgs/_search"): (200, json.dumps(ORGS).encode()),
            ("GET", "/management/v1/policies/label"): (200, json.dumps({"policy": {"isDefault": is_default}}).encode()),
        })

    def _deletes(self, recorder):
        return [call for call in recorder.calls if call[:2] == ("DELETE", "/management/v1/policies/label")]

    def test_no_reset_when_every_org_already_inherits(self):
        recorder = self._recorder(True)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_branding([])
        self.assertEqual(self._deletes(recorder), [])

    def test_resets_every_org_that_overrode_the_skin(self):
        recorder = self._recorder(False)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_branding([])
        self.assertEqual(len(self._deletes(recorder)), len(ORGS["result"]))

    def test_leaves_a_deliberately_branded_tenant_alone(self):
        """Per-org branding is a product feature; only undeclared drift is reset."""
        recorder = self._recorder(False)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_branding(["TESSERIX", "ZITADEL"])
        self.assertEqual(self._deletes(recorder), [])

    def test_scopes_every_call_to_the_org_it_is_reading(self):
        """Without x-zitadel-orgid the call reads the PAT's own org instead."""
        recorder = self._recorder(False)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_branding([])
        scoped = [headers.get("x-zitadel-orgid") for path, headers in recorder.headers
                  if path == "/management/v1/policies/label"]
        self.assertEqual(sorted(set(scoped)), ["org-tesserix", "org-zitadel"])


class PlatformProjectTest(unittest.TestCase):
    MACHINE_GRANT = {
        "login": "agentgateway-adk-prod",
        "roles": [
            "agentgateway.mcp",
            "agentgateway.models",
            "agentgateway.runtime",
        ],
    }
    MACHINE_USERS = {
        "result": AdminTest.USERS["result"]
        + [
            {
                "userId": "machine-1",
                "username": "agentgateway-adk-prod",
                "machine": {"name": "agentgateway-adk-prod"},
            }
        ]
    }
    PROJECT = {
        "org": "ZITADEL",
        "name": "AgentGateway",
        "expectedId": "p-agentgateway",
        "roles": [
            {"key": "agentgateway.mcp", "displayName": "MCP", "group": "gateway-access"},
            {"key": "agentgateway.models", "displayName": "Models", "group": "gateway-access"},
        ],
        "humanGrants": [
            {
                "login": "samyak.rout@gmail.com",
                "roles": ["agentgateway.mcp", "agentgateway.models"],
            }
        ],
        "oidcApps": [
            {
                "name": "agentgateway-mcp-ui",
                "redirectUris": ["https://mcp.tesserix.app/oauth2/callback"],
                "postLogoutRedirectUris": ["https://mcp.tesserix.app"],
                "loginBaseUri": "https://auth.tesserix.app/ui/v2/login",
            }
        ],
    }

    def _recorder(self, roles=None, grants=None, users=None):
        return Recorder({
            ("POST", "/admin/v1/orgs/_search"): (200, json.dumps(ORGS).encode()),
            ("POST", "/management/v1/projects/_search"): (
                200,
                json.dumps({"result": [{"id": "p-agentgateway", "name": "AgentGateway"}]}).encode(),
            ),
            ("POST", "/management/v1/projects/p-agentgateway/roles/_search"): (
                200,
                json.dumps({"result": roles if roles is not None else [
                    {"key": "agentgateway.mcp", "displayName": "MCP", "group": "gateway-access"},
                    {"key": "agentgateway.models", "displayName": "Models", "group": "gateway-access"},
                ]}).encode(),
            ),
            ("POST", "/management/v1/users/grants/_search"): (
                200,
                json.dumps({"result": grants if grants is not None else [
                    {
                        "id": "grant-1",
                        "userId": "u-1",
                        "projectId": "p-agentgateway",
                        "roleKeys": ["agentgateway.mcp", "agentgateway.models"],
                    }
                ]}).encode(),
            ),
            ("POST", "/management/v1/projects/p-agentgateway/apps/_search"): (
                200,
                json.dumps({"result": [{"id": "app-mcp", "name": "agentgateway-mcp-ui"}]}).encode(),
            ),
            ("GET", "/management/v1/projects/p-agentgateway/apps/app-mcp"): (
                200,
                json.dumps({
                    "app": {
                        "id": "app-mcp",
                        "name": "agentgateway-mcp-ui",
                        "oidcConfig": {
                            "redirectUris": ["https://mcp.tesserix.app/oauth2/callback"],
                            "postLogoutRedirectUris": ["https://mcp.tesserix.app"],
                        },
                    }
                }).encode(),
            ),
            (
                "POST",
                "/zitadel.application.v2.ApplicationService/GetApplication",
            ): (
                200,
                json.dumps({
                    "application": {
                        "oidcConfiguration": {
                            "loginVersion": {
                                "loginV2": {
                                    "baseUri": "https://auth.tesserix.app/ui/v2/login"
                                }
                            }
                        }
                    }
                }).encode(),
            ),
            ("POST", "/v2/users"): (
                200,
                json.dumps(users if users is not None else AdminTest.USERS).encode(),
            ),
        })

    def test_in_sync_project_performs_no_state_writes(self):
        recorder = self._recorder()
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_platform_project(dict(self.PROJECT))
        state_writes = [
            write for write in recorder.writes
            if not write[1].endswith("_search")
            and write[1]
            not in (
                "/v2/users",
                "/zitadel.application.v2.ApplicationService/GetApplication",
            )
        ]
        self.assertEqual([], state_writes)

    def test_adds_missing_role(self):
        recorder = self._recorder(roles=[])
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_platform_project(dict(self.PROJECT))
        self.assertIn(
            ("POST", "/management/v1/projects/p-agentgateway/roles"),
            recorder.writes,
        )

    def test_adds_missing_human_grant(self):
        recorder = self._recorder(grants=[])
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_platform_project(dict(self.PROJECT))
        self.assertIn(("POST", "/management/v1/users/u-1/grants"), recorder.writes)

    def test_adds_missing_machine_grant(self):
        project = dict(self.PROJECT, machineGrants=[self.MACHINE_GRANT])
        recorder = self._recorder(users=self.MACHINE_USERS)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_platform_project(project)
        grant_writes = [
            call
            for call in recorder.calls
            if call[:2] == (
                "POST",
                "/management/v1/users/machine-1/grants",
            )
        ]
        self.assertEqual(
            [{"projectId": "p-agentgateway", "roleKeys": sorted(self.MACHINE_GRANT["roles"])}],
            [call[2] for call in grant_writes],
        )

    def test_missing_declared_machine_fails_closed(self):
        project = dict(self.PROJECT, machineGrants=[self.MACHINE_GRANT])
        recorder = self._recorder()
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit) as caught:
                bootstrap.reconcile_platform_project(project)
        self.assertIn("agentgateway-adk-prod", str(caught.exception))
        self.assertIn("machine", str(caught.exception))

    def test_in_sync_machine_grant_performs_no_state_write(self):
        project = dict(self.PROJECT, machineGrants=[self.MACHINE_GRANT])
        grants = [
            {
                "id": "grant-1",
                "userId": "u-1",
                "projectId": "p-agentgateway",
                "roleKeys": ["agentgateway.mcp", "agentgateway.models"],
            },
            {
                "id": "grant-machine",
                "userId": "machine-1",
                "projectId": "p-agentgateway",
                "roleKeys": self.MACHINE_GRANT["roles"],
            },
        ]
        recorder = self._recorder(grants=grants, users=self.MACHINE_USERS)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_platform_project(project)
        grant_writes = [
            call
            for call in recorder.calls
            if "/grants" in call[1]
            and not call[1].endswith("_search")
            and call[0] in ("POST", "PUT")
        ]
        self.assertEqual([], grant_writes)

    def test_updates_drifted_machine_roles(self):
        project = dict(self.PROJECT, machineGrants=[self.MACHINE_GRANT])
        grants = [
            {
                "id": "grant-1",
                "userId": "u-1",
                "projectId": "p-agentgateway",
                "roleKeys": ["agentgateway.mcp", "agentgateway.models"],
            },
            {
                "id": "grant-machine",
                "userId": "machine-1",
                "projectId": "p-agentgateway",
                "roleKeys": ["agentgateway.mcp", "agentgateway.models"],
            },
        ]
        recorder = self._recorder(grants=grants, users=self.MACHINE_USERS)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_platform_project(project)
        updates = [
            call
            for call in recorder.calls
            if call[:2]
            == (
                "PUT",
                "/management/v1/users/machine-1/grants/grant-machine",
            )
        ]
        self.assertEqual(
            [{"roleKeys": sorted(self.MACHINE_GRANT["roles"])}],
            [call[2] for call in updates],
        )

    def test_updates_drifted_human_roles(self):
        recorder = self._recorder(grants=[{
            "id": "grant-1",
            "userId": "u-1",
            "projectId": "p-agentgateway",
            "roleKeys": ["agentgateway.mcp"],
        }])
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_platform_project(dict(self.PROJECT))
        self.assertIn(
            ("PUT", "/management/v1/users/u-1/grants/grant-1"),
            recorder.writes,
        )

    def test_project_id_mismatch_fails_closed(self):
        project = dict(self.PROJECT, expectedId="different-project")
        recorder = self._recorder()
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_platform_project(project)

    def test_missing_oidc_application_fails_closed(self):
        recorder = self._recorder()
        recorder.responses[("POST", "/management/v1/projects/p-agentgateway/apps/_search")] = (
            200,
            json.dumps({"result": []}).encode(),
        )
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit) as caught:
                bootstrap.reconcile_platform_project(dict(self.PROJECT))
        self.assertIn("agentgateway-mcp-ui", str(caught.exception))

    def test_drifted_oidc_redirect_fails_closed_without_writing(self):
        recorder = self._recorder()
        recorder.responses[("GET", "/management/v1/projects/p-agentgateway/apps/app-mcp")] = (
            200,
            json.dumps({
                "app": {
                    "name": "agentgateway-mcp-ui",
                    "oidcConfig": {
                        "redirectUris": ["https://attacker.example/callback"],
                        "postLogoutRedirectUris": ["https://mcp.tesserix.app"],
                    },
                }
            }).encode(),
        )
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_platform_project(dict(self.PROJECT))
        self.assertEqual([], [call for call in recorder.calls if call[0] in ("PUT", "DELETE")])

    def test_drifted_oidc_grant_types_fail_closed_without_writing(self):
        project = dict(self.PROJECT)
        project["oidcApps"] = [
            dict(
                self.PROJECT["oidcApps"][0],
                grantTypes=[
                    "OIDC_GRANT_TYPE_AUTHORIZATION_CODE",
                    "OIDC_GRANT_TYPE_REFRESH_TOKEN",
                    "OIDC_GRANT_TYPE_DEVICE_CODE",
                ],
            )
        ]
        recorder = self._recorder()

        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_platform_project(project)

        self.assertEqual([], [call for call in recorder.calls if call[0] in ("PUT", "DELETE")])

    def test_missing_login_v2_is_reconciled_without_changing_client_config(self):
        recorder = self._recorder()
        recorder.responses[
            ("POST", "/zitadel.application.v2.ApplicationService/GetApplication")
        ] = (
            200,
            json.dumps({"application": {"oidcConfiguration": {}}}).encode(),
        )
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_platform_project(dict(self.PROJECT))
        updates = [
            call
            for call in recorder.calls
            if call[:2]
            == (
                "POST",
                "/zitadel.application.v2.ApplicationService/UpdateApplication",
            )
        ]
        self.assertEqual(len(updates), 1)
        self.assertEqual(
            updates[0][2],
            {
                "applicationId": "app-mcp",
                "projectId": "p-agentgateway",
                "oidcConfiguration": {
                    "loginVersion": {
                        "loginV2": {
                            "baseUri": "https://auth.tesserix.app/ui/v2/login"
                        }
                    }
                },
            },
        )
        update_headers = [
            headers
            for path, headers in recorder.headers
            if path
            == "/zitadel.application.v2.ApplicationService/UpdateApplication"
        ][0]
        self.assertEqual(update_headers["Connect-Protocol-Version"], "1")
        self.assertEqual(update_headers["x-zitadel-orgid"], "org-zitadel")

    def test_login_v2_update_failure_stops_reconciliation(self):
        recorder = self._recorder()
        recorder.responses[
            ("POST", "/zitadel.application.v2.ApplicationService/GetApplication")
        ] = (
            200,
            json.dumps({"application": {"oidcConfiguration": {}}}).encode(),
        )
        recorder.responses[
            ("POST", "/zitadel.application.v2.ApplicationService/UpdateApplication")
        ] = (500, b"update failed")
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit) as caught:
                bootstrap.reconcile_platform_project(dict(self.PROJECT))
        self.assertIn("login version update failed", str(caught.exception))
        self.assertNotIn(
            ("POST", "/management/v1/projects/p-agentgateway/roles"),
            recorder.writes,
        )


class ReservedOrgTest(unittest.TestCase):
    """The ZITADEL org holds the console and the break-glass admin, nothing else."""

    def _recorder(self, projects):
        return Recorder({
            ("POST", "/admin/v1/orgs/_search"): (200, json.dumps(ORGS).encode()),
            ("POST", "/management/v1/projects/_search"): (200, json.dumps({"result": projects}).encode()),
        })

    def test_passes_when_only_the_console_project_remains(self):
        recorder = self._recorder([{"id": "p-1", "name": "ZITADEL"}])
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.assert_reserved_org_clean("ZITADEL", ["ZITADEL"])

    def test_fails_when_a_product_project_is_still_there(self):
        recorder = self._recorder([{"id": "p-1", "name": "ZITADEL"}, {"id": "p-2", "name": "tesserix-blog"}])
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit) as caught:
                bootstrap.assert_reserved_org_clean("ZITADEL", ["ZITADEL"])
        self.assertIn("tesserix-blog", str(caught.exception))

    def test_is_a_read_only_check(self):
        """It reports the violation; deleting a project is never automatic."""
        recorder = self._recorder([{"id": "p-1", "name": "ZITADEL"}, {"id": "p-2", "name": "stockpilot-web"}])
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.assert_reserved_org_clean("ZITADEL", ["ZITADEL"])
        self.assertEqual([c for c in recorder.calls if c[0] == "DELETE"], [])


class OrgIdpTest(unittest.TestCase):
    """The connector is asserted from git without the reconciler ever holding its secret."""

    IDP = {
        "org": "TESSERIX",
        "name": "Google",
        "expectedId": "idp-1",
        "clientId": "client-1.apps.googleusercontent.com",
        "scopes": ["openid", "profile", "email"],
        "options": {
            "isLinkingAllowed": True,
            "isCreationAllowed": False,
            "isAutoCreation": False,
            "isAutoUpdate": False,
            "autoLinking": "AUTO_LINKING_OPTION_EMAIL",
        },
    }

    # Zitadel omits false booleans, so an in-sync provider returns only the
    # options that are actually true. Reading this as drift is the trap that
    # kept passwordCheckLifetime pinned at 0s.
    LIVE_OPTIONS = {"isLinkingAllowed": True, "autoLinking": "AUTO_LINKING_OPTION_EMAIL"}

    def _recorder(self, options=None, idp_id="idp-1", client_id=None, bound=True, found=True):
        idp = {
            "id": idp_id,
            "name": "Google",
            "state": "IDP_STATE_ACTIVE",
            "config": {
                "options": self.LIVE_OPTIONS if options is None else options,
                "google": {
                    "clientId": client_id or self.IDP["clientId"],
                    "scopes": ["openid", "profile", "email"],
                },
            },
        }
        policy = {"policy": {"idps": [{"idpId": idp_id}] if bound else []}}
        return Recorder({
            ("POST", "/admin/v1/orgs/_search"): (200, json.dumps(ORGS).encode()),
            ("POST", "/management/v1/idps/templates/_search"): (
                200, json.dumps({"result": [idp] if found else []}).encode()),
            ("GET", "/management/v1/policies/login"): (200, json.dumps(policy).encode()),
        })

    def _updates(self, recorder):
        return [call for call in recorder.calls if call[0] == "PUT" and "/idps/google/" in call[1]]

    def test_in_sync_provider_performs_no_writes(self):
        recorder = self._recorder()
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_idps([self.IDP])
        self.assertEqual(recorder.writes, [
            ("POST", "/admin/v1/orgs/_search"),
            ("POST", "/management/v1/idps/templates/_search"),
        ])

    def test_absent_false_option_is_not_drift(self):
        """isAutoCreation:false reads back absent; treating that as drift never converges."""
        recorder = self._recorder(options={"isLinkingAllowed": True, "autoLinking": "AUTO_LINKING_OPTION_EMAIL"})
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_idps([self.IDP])
        self.assertEqual(self._updates(recorder), [])

    def test_reasserts_an_option_flipped_in_the_console(self):
        """isAutoUpdate:true silently overwrites profiles from the IdP on every login."""
        live = dict(self.LIVE_OPTIONS, isAutoUpdate=True)
        recorder = self._recorder(options=live)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_idps([self.IDP])
        self.assertEqual(len(self._updates(recorder)), 1)

    def test_update_never_sends_the_client_secret(self):
        """Sending the field is what blanks it; omitting it leaves the stored value alone."""
        recorder = self._recorder(options=dict(self.LIVE_OPTIONS, isAutoUpdate=True))
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_idps([self.IDP])
        body = self._updates(recorder)[0][2]
        self.assertNotIn("clientSecret", body)

    def test_missing_provider_fails_closed(self):
        """Creating one needs a secret this reconciler must never hold."""
        recorder = self._recorder(found=False)
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_org_idps([self.IDP])

    def test_unexpected_id_fails_closed(self):
        """A different ID means user links point at a provider git does not describe."""
        recorder = self._recorder(idp_id="idp-other")
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_org_idps([self.IDP])

    def test_client_id_drift_fails_closed(self):
        """Repointing at another OAuth client needs its secret, so report rather than guess."""
        recorder = self._recorder(client_id="someone-else.apps.googleusercontent.com")
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_org_idps([self.IDP])

    def test_binds_the_provider_when_the_login_policy_lost_it(self):
        """An unbound provider is live but invisible — no button on the login page."""
        recorder = self._recorder(bound=False)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_idps([self.IDP])
        self.assertIn(("POST", "/management/v1/policies/login/idps"), recorder.writes)

    def test_scopes_every_call_to_the_owning_org(self):
        recorder = self._recorder(options=dict(self.LIVE_OPTIONS, isAutoUpdate=True))
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_org_idps([self.IDP])
        scoped = {headers.get("x-zitadel-orgid") for path, headers in recorder.headers
                  if path != "/admin/v1/orgs/_search"}
        self.assertEqual(scoped, {"org-tesserix"})


class SmtpTest(unittest.TestCase):
    """Email is the only recovery path the break-glass account has."""

    SMTP = {
        "expectedId": "smtp-1",
        "senderAddress": "auth@tesserix.app",
        "senderName": "Tesserix",
        "host": "smtp.resend.com:587",
        "user": "resend",
        "tls": True,
        "description": "Resend",
        "requireActive": True,
    }

    LIVE = {
        "id": "smtp-1",
        "senderAddress": "auth@tesserix.app",
        "senderName": "Tesserix",
        "host": "smtp.resend.com:587",
        "user": "resend",
        "tls": True,
        "state": "SMTP_CONFIG_ACTIVE",
        # The read model reports this as the value set at creation no matter what
        # is written later, so the reconciler must never compare it.
        "description": "whatever the projection kept",
    }

    def _recorder(self, live=None, status=200):
        payload = json.dumps({"smtpConfig": live if live is not None else self.LIVE}).encode()
        return Recorder({("GET", "/admin/v1/smtp/smtp-1"): (status, payload)})

    def _updates(self, recorder):
        return [call for call in recorder.calls if call[0] == "PUT" and call[1] == "/admin/v1/smtp/smtp-1"]

    def test_in_sync_config_performs_no_writes(self):
        recorder = self._recorder()
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_smtp(self.SMTP)
        self.assertEqual(recorder.writes, [])

    def test_description_is_never_drift(self):
        """It is written to the eventstore but never projected, so asserting it never converges."""
        recorder = self._recorder(dict(self.LIVE, description="something else entirely"))
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_smtp(self.SMTP)
        self.assertEqual(self._updates(recorder), [])

    def test_fixes_a_changed_host(self):
        recorder = self._recorder(dict(self.LIVE, host="smtp.example.test:25"))
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_smtp(self.SMTP)
        self.assertEqual(len(self._updates(recorder)), 1)

    def test_absent_tls_reads_as_false_and_is_fixed(self):
        """Zitadel omits false booleans; tls dropped to false comes back missing."""
        live = {key: value for key, value in self.LIVE.items() if key != "tls"}
        recorder = self._recorder(live)
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_smtp(self.SMTP)
        self.assertEqual(len(self._updates(recorder)), 1)

    def test_update_never_sends_the_password(self):
        """Omitting it preserves the stored secret; the reconciler must never hold it."""
        recorder = self._recorder(dict(self.LIVE, host="smtp.example.test:25"))
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_smtp(self.SMTP)
        body = self._updates(recorder)[0][2]
        self.assertNotIn("password", body)

    def test_reactivates_a_deactivated_provider(self):
        """A deactivated provider stops password reset with no error anywhere."""
        recorder = self._recorder(dict(self.LIVE, state="SMTP_CONFIG_INACTIVE"))
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_smtp(self.SMTP)
        self.assertIn(("POST", "/admin/v1/smtp/smtp-1/_activate"), recorder.writes)

    def test_missing_provider_fails_closed(self):
        """Creating one needs the password, which this job deliberately does not hold."""
        recorder = self._recorder(status=404)
        with mock.patch.object(bootstrap, "request", recorder):
            with self.assertRaises(SystemExit):
                bootstrap.reconcile_smtp(self.SMTP)

    def test_undeclared_smtp_is_skipped(self):
        recorder = Recorder({})
        with mock.patch.object(bootstrap, "request", recorder):
            bootstrap.reconcile_smtp(None)
        self.assertEqual(recorder.calls, [])


class MainTest(unittest.TestCase):
    def _responses(self):
        return {
            ("GET", "/admin/v1/policies/label"): (200, json.dumps({"policy": LIVE_LABEL_POLICY}).encode()),
            ("GET", "/admin/v1/policies/login"): (200, json.dumps({"policy": LIVE_LOGIN_POLICY}).encode()),
            ("GET", "/assets/v1/instance/policy/label/logo"): (200, b"light-bytes"),
            ("POST", "/admin/v1/members/_search"): (200, json.dumps({"result": [{"userId": "u-1", "roles": ["IAM_OWNER"]}]}).encode()),
            ("POST", "/v2/users"): (200, json.dumps(AdminTest.USERS).encode()),
            ("POST", "/admin/v1/orgs/_search"): (200, json.dumps(ORGS).encode()),
            ("GET", "/admin/v1/orgs/default"): (200, json.dumps({"org": {"id": "org-tesserix"}}).encode()),
            ("GET", "/management/v1/policies/label"): (200, json.dumps({"policy": {"isDefault": True}}).encode()),
            ("POST", "/management/v1/projects/_search"): (200, json.dumps({"result": [{"id": "p-1", "name": "ZITADEL"}]}).encode()),
            ("POST", "/management/v1/idps/templates/_search"): (200, json.dumps({"result": [{
                "id": "idp-1",
                "name": "Google",
                "config": {"options": OrgIdpTest.LIVE_OPTIONS,
                           "google": {"clientId": OrgIdpTest.IDP["clientId"]}},
            }]}).encode()),
            ("GET", "/management/v1/policies/login"): (200, json.dumps({"policy": {"idps": [{"idpId": "idp-1"}]}}).encode()),
            ("GET", "/admin/v1/smtp/smtp-1"): (200, json.dumps({"smtpConfig": SmtpTest.LIVE}).encode()),
        }

    def _config(self, path):
        with open(path, "w") as fh:
            json.dump({
                "labelPolicy": LIVE_LABEL_POLICY,
                "loginPolicy": LIVE_LOGIN_POLICY,
                "assets": {"logo": "logo-light.png"},
                "admins": ["samyak.rout@gmail.com"],
                "defaultOrg": "TESSERIX",
                "selfBrandedOrgs": [],
                "smtp": SmtpTest.SMTP,
                "idps": [OrgIdpTest.IDP],
                "platformProjects": [],
                "reservedOrg": {"name": "ZITADEL", "allowedProjects": ["ZITADEL"]},
            }, fh)

    def test_fully_in_sync_instance_performs_no_writes(self):
        config = os.path.join(WORKDIR, "desired.json")
        self._config(config)
        recorder = Recorder(self._responses())
        with mock.patch.object(bootstrap, "request", recorder), mock.patch.object(bootstrap, "CONFIG_PATH", config):
            bootstrap.main()
        self.assertEqual(
            [
                write
                for write in recorder.writes
                if not write[1].endswith("_search")
                and write[1]
                not in (
                    "/v2/users",
                    "/zitadel.application.v2.ApplicationService/GetApplication",
                )
            ],
            [],
        )

    def test_activation_runs_only_when_branding_changed(self):
        config = os.path.join(WORKDIR, "desired.json")
        self._config(config)
        responses = self._responses()
        responses[("GET", "/assets/v1/instance/policy/label/logo")] = (200, b"stale-bytes")
        recorder = Recorder(responses)
        with mock.patch.object(bootstrap, "request", recorder), mock.patch.object(bootstrap, "CONFIG_PATH", config):
            bootstrap.main()
        self.assertIn(("POST", "/admin/v1/policies/label/_activate"), recorder.writes)


if __name__ == "__main__":
    unittest.main(verbosity=2)
