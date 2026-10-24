import json
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart, *values):
    args = ["helm", "template", "helivanta-global-api", str(ROOT / "charts/apps" / chart), "--namespace", "helivanta"]
    for value in values:
        args.extend(["--set", value])
    return [x for x in yaml.safe_load_all(subprocess.check_output(args, text=True)) if x]


def test_global_api_has_its_own_unprivileged_identity_and_bounded_resources():
    rows = render("helivanta-global-api", "image.tag=reviewed-image")
    deployment = next(x for x in rows if x["kind"] == "Deployment")
    pod = deployment["spec"]["template"]["spec"]
    assert deployment["spec"]["replicas"] == 2
    assert pod["serviceAccountName"] == "helivanta-global-api"
    assert pod["automountServiceAccountToken"] is False
    c = pod["containers"][0]
    assert c["command"] == ["/app/global-api"]
    assert c["securityContext"]["readOnlyRootFilesystem"] is True
    assert c["resources"]["limits"]["memory"] == "1Gi"
    assert "cpu" not in c["resources"]["requests"]
    env = {x["name"]: x["value"] for x in c["env"]}
    assert env["GLOBAL_API_TRANSPORT_SECURITY"] == "istio"
    assert set(json.loads(env["GLOBAL_API_UPSTREAMS"])) == {"platform", "medicore", "workforce", "pharmacy", "supply", "lab", "emergency", "mediconnect"}
    assert json.loads(env["GLOBAL_API_UPSTREAMS"])["mediconnect"] == "http://helivanta-api.helivanta.svc.cluster.local:8080"
    assert not any(x["kind"] in {"Secret", "ExternalSecret", "Job"} for x in rows)
    assert any(x["kind"] == "PeerAuthentication" and x["spec"]["mtls"]["mode"] == "STRICT" for x in rows)
    assert any(x["kind"] == "PodDisruptionBudget" for x in rows)


def test_new_connector_is_excluded_from_permissive_network_rules():
    rows = render("helivanta-network-policies")
    for name in ["allow-intra-namespace", "allow-egress-external", "allow-istio-ingress", "allow-hbone-15008"]:
        policy = next(x for x in rows if x["metadata"]["name"] == name)
        rules = policy["spec"]["podSelector"]["matchExpressions"]
        assert any(r["operator"] == "NotIn" and "helivanta-global-api" in r["values"] for r in rules)
