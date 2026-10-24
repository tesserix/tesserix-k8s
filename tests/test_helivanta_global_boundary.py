import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_product_api_rejects_callers_other_than_the_global_api():
    raw = subprocess.check_output(
        ["helm", "template", "helivanta-global-api", str(ROOT / "charts/apps/helivanta-global-api"), "--namespace", "helivanta"],
        text=True,
    )
    policies = [x for x in yaml.safe_load_all(raw) if x and x["kind"] == "AuthorizationPolicy"]
    deny = next((x for x in policies if x["metadata"]["name"] == "helivanta-owner-requires-global-api"), None)
    assert deny is not None, "The production owner must reject direct client access"
    assert deny["spec"]["selector"]["matchLabels"] == {"app.kubernetes.io/name": "helivanta-api"}
    assert deny["spec"]["action"] == "DENY"
    assert deny["spec"]["rules"] == [{
        "from": [{"source": {"notPrincipals": ["cluster.local/ns/helivanta/sa/helivanta-global-api"]}}],
        "to": [{"operation": {"ports": ["8080"]}}],
    }]
