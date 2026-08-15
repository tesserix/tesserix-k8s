"""Tests for migrate-zitadel-project.py. Run with `python3 migrate_zitadel_project_test.py`."""

import importlib.util
import os
import unittest

_spec = importlib.util.spec_from_file_location(
    "migrate", os.path.join(os.path.dirname(os.path.abspath(__file__)), "migrate-zitadel-project.py"))
migrate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(migrate)

# tesserix-blog-web as the API returns it, protobuf defaults omitted.
LIVE_APP = {
    "id": "386314489026314892",
    "state": "APP_STATE_ACTIVE",
    "name": "tesserix-blog-web",
    "details": {"sequence": "3"},
    "oidcConfig": {
        "redirectUris": ["https://blog.tesserix.app/api/auth/callback"],
        "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
        "grantTypes": ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
        "clientId": "386314489043092108",
        "postLogoutRedirectUris": ["https://blog.tesserix.app/"],
        "accessTokenType": "OIDC_TOKEN_TYPE_JWT",
        "accessTokenRoleAssertion": True,
        "idTokenRoleAssertion": True,
        "idTokenUserinfoAssertion": True,
        "clockSkew": "0s",
        "allowedOrigins": ["https://blog.tesserix.app"],
    },
}


class CreatePayloadTest(unittest.TestCase):
    def setUp(self):
        self.payload = migrate.create_payload(LIVE_APP)

    def test_carries_the_name(self):
        self.assertEqual(self.payload["name"], "tesserix-blog-web")

    def test_preserves_redirect_and_logout_uris(self):
        """A dropped redirect URI fails the login only at the callback, after auth."""
        self.assertEqual(self.payload["redirectUris"], ["https://blog.tesserix.app/api/auth/callback"])
        self.assertEqual(self.payload["postLogoutRedirectUris"], ["https://blog.tesserix.app/"])

    def test_preserves_grant_and_response_types(self):
        self.assertEqual(self.payload["grantTypes"],
                         ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"])
        self.assertEqual(self.payload["responseTypes"], ["OIDC_RESPONSE_TYPE_CODE"])

    def test_preserves_token_assertions_and_origins(self):
        self.assertEqual(self.payload["accessTokenType"], "OIDC_TOKEN_TYPE_JWT")
        self.assertTrue(self.payload["idTokenUserinfoAssertion"])
        self.assertEqual(self.payload["allowedOrigins"], ["https://blog.tesserix.app"])

    def test_restates_the_omitted_protobuf_defaults(self):
        """Absent means WEB/BASIC; left out, the new app is created the wrong type."""
        self.assertEqual(self.payload["appType"], "OIDC_APP_TYPE_WEB")
        self.assertEqual(self.payload["authMethodType"], "OIDC_AUTH_METHOD_TYPE_BASIC")
        self.assertFalse(self.payload["devMode"])

    def test_does_not_honour_an_explicit_non_default_type(self):
        """An SPA app must stay an SPA, not be coerced to the web default."""
        spa = {"name": "spa", "oidcConfig": dict(LIVE_APP["oidcConfig"],
                                                 appType="OIDC_APP_TYPE_USER_AGENT",
                                                 authMethodType="OIDC_AUTH_METHOD_TYPE_NONE")}
        payload = migrate.create_payload(spa)
        self.assertEqual(payload["appType"], "OIDC_APP_TYPE_USER_AGENT")
        self.assertEqual(payload["authMethodType"], "OIDC_AUTH_METHOD_TYPE_NONE")

    def test_drops_server_owned_identity_fields(self):
        """Carrying the old clientId over would collide or be silently ignored."""
        for key in ("clientId", "clientSecret", "details", "state", "id"):
            self.assertNotIn(key, self.payload)


if __name__ == "__main__":
    unittest.main(verbosity=2)
