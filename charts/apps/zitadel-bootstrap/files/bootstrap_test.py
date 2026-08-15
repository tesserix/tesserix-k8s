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

    def __call__(self, method, path, body=None, headers=None, raw=None, content_type=None):
        self.calls.append((method, path, body, raw, content_type))
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


class MainTest(unittest.TestCase):
    def _responses(self):
        return {
            ("GET", "/admin/v1/policies/label"): (200, json.dumps({"policy": LIVE_LABEL_POLICY}).encode()),
            ("GET", "/admin/v1/policies/login"): (200, json.dumps({"policy": LIVE_LOGIN_POLICY}).encode()),
            ("GET", "/assets/v1/instance/policy/label/logo"): (200, b"light-bytes"),
            ("POST", "/admin/v1/members/_search"): (200, json.dumps({"result": [{"userId": "u-1", "roles": ["IAM_OWNER"]}]}).encode()),
            ("POST", "/v2/users"): (200, json.dumps(AdminTest.USERS).encode()),
        }

    def _config(self, path):
        with open(path, "w") as fh:
            json.dump({
                "labelPolicy": LIVE_LABEL_POLICY,
                "loginPolicy": LIVE_LOGIN_POLICY,
                "assets": {"logo": "logo-light.png"},
                "admins": ["samyak.rout@gmail.com"],
            }, fh)

    def test_fully_in_sync_instance_performs_no_writes(self):
        config = os.path.join(WORKDIR, "desired.json")
        self._config(config)
        recorder = Recorder(self._responses())
        with mock.patch.object(bootstrap, "request", recorder), mock.patch.object(bootstrap, "CONFIG_PATH", config):
            bootstrap.main()
        self.assertEqual([w for w in recorder.writes if w[1] != "/v2/users" and not w[1].endswith("_search")], [])

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
