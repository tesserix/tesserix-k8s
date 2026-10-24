import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_every_public_business_route_targets_global_api():
    raw = subprocess.check_output(["helm", "template", "helivanta-istio", str(ROOT / "charts/apps/helivanta-istio"), "--namespace", "helivanta"], text=True)
    vs = next(x for x in yaml.safe_load_all(raw) if x and x["kind"] == "VirtualService")
    routes = [x for x in vs["spec"]["http"] if "rewrite" in x]
    assert len(routes) == 2
    for route in routes:
        assert route["route"][0]["destination"] == {"host": "helivanta-global-api.helivanta.svc.cluster.local", "port": {"number": 8081}}
    values = yaml.safe_load((ROOT / "charts/apps/helivanta-shell/values.yaml").read_text())
    assert values["apiUrl"] == "http://helivanta-global-api.helivanta.svc.cluster.local:8081"
