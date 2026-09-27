import json
import re
from test_homechef_openbao_access import render, resource

GATEWAY_KEYS = [
    "cashfree-app-id",
    "cashfree-secret-key",
    "cashfree-webhook-secret",
    "cashfree-test-app-id",
    "cashfree-test-secret-key",
    "cashfree-test-webhook-secret",
    "cashfree-payout-client-id",
    "cashfree-payout-client-secret",
    "cashfree-payout-webhook-secret",
    "cashfree-payout-public-key",
    "cashfree-payout-test-client-id",
    "cashfree-payout-test-client-secret",
    "cashfree-payout-test-webhook-secret",
    "cashfree-payout-test-public-key",
    "stripe-secret-key",
    "stripe-publishable-key",
    "stripe-webhook-secret",
]


def test_runtime_writer_has_only_gateway_and_payment_owner_capabilities():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    policy = config["policy-runtime-fe3dr-payment.hcl"]
    paths = dict(re.findall(r'path "([^"]+)" \{ capabilities = \[([^]]+)\] \}', policy))
    prefix = "kv/data/homechef/homechef-api/fe3dr-"
    expected = {prefix + key: '"create", "read", "update"' for key in GATEWAY_KEYS}
    for owner in ["vendor", "driver"]:
        expected[prefix + owner + "-payment-*"] = '"create", "read", "update"'
        expected["kv/metadata/homechef/homechef-api/fe3dr-" + owner + "-payment-*"] = (
            '"delete"'
        )
    assert paths == expected
    role = json.loads(config["role-runtime-fe3dr-payment.json"])
    assert role["bound_service_account_names"] == ["homechef-api"]
    assert role["bound_service_account_namespaces"] == ["homechef"]
    assert role["token_policies"] == ["runtime-fe3dr-payment"]
    assert role["token_ttl"] == "10m"
