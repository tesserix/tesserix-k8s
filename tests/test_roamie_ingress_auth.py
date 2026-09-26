import unittest

from test_agentgateway_public_access import render_istio_auth_policies, resource


class RoamieIngressAuthTests(unittest.TestCase):
    def test_roamie_tokens_reach_api_on_both_gateways(self):
        documents = render_istio_auth_policies()
        for suffix in ("", "-custom"):
            jwt = resource(documents, "RequestAuthentication", f"jwt-auth-gip-agentgateway-zitadel{suffix}")
            rule = jwt["spec"]["jwtRules"][0]
            self.assertIn("392328861469115174", rule["audiences"])
            self.assertTrue(rule["forwardOriginalToken"])
            deny = resource(documents, "AuthorizationPolicy", f"deny-foreign-hosts-gip-agentgateway-zitadel{suffix}")
            hosts = deny["spec"]["rules"][0]["to"][0]["operation"]["notHosts"]
            self.assertIn("roamie-api.tesserix.app", hosts)
            self.assertNotIn("*", hosts)
