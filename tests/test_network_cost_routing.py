import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def render(chart, release, namespace, values=(), settings=()):
    cmd = ["helm", "template", release, str(ROOT / chart), "--namespace", namespace]
    for value in values:
        cmd += ["-f", str(ROOT / value)]
    for setting in settings:
        cmd += ["--set", setting]
    return [x for x in yaml.safe_load_all(subprocess.check_output(cmd, text=True)) if x]


def test_production_ingress_prefers_local_ready_endpoints_without_restricting_failover():
    app = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/istio-ingress-gateway.yaml").read_text()
    )
    values = app["spec"]["source"]["helm"]["values"]
    cmd = [
        "helm",
        "template",
        "istio-ingressgateway",
        str(ROOT / "charts/thirdparty/istio-ingress-gateway"),
        "--namespace",
        "istio-ingress",
        "-f",
        "-",
    ]
    docs = [
        x
        for x in yaml.safe_load_all(
            subprocess.check_output(cmd, input=values, text=True)
        )
        if x
    ]
    svc = next(x for x in docs if x["kind"] == "Service")
    assert svc["spec"]["trafficDistribution"] == "PreferSameZone"
    assert svc["spec"].get("internalTrafficPolicy", "Cluster") == "Cluster"
    assert svc["spec"]["type"] == "ClusterIP"
    assert svc["spec"]["selector"]["istio"] == "ingressgateway"


def test_waypoints_prefer_same_zone_and_keep_hbone_authorization_path():
    docs = render(
        "charts/thirdparty/istio-config",
        "istio-config",
        "istio-system",
        values=("charts/thirdparty/istio-config/values-prod.yaml",),
    )
    gateways = [
        x
        for x in docs
        if x["kind"] == "Gateway" and x["metadata"]["name"] == "waypoint"
    ]
    assert gateways
    for gateway in gateways:
        assert (
            gateway["spec"]["infrastructure"]["annotations"][
                "networking.istio.io/traffic-distribution"
            ]
            == "PreferSameZone"
        )
        assert gateway["spec"]["listeners"] == [
            {
                "name": "mesh",
                "port": 15008,
                "protocol": "HBONE",
                "allowedRoutes": {"namespaces": {"from": "Same"}},
            }
        ]
        assert gateway["metadata"]["labels"]["istio.io/waypoint-for"] == "service"


def test_waypoint_listener_declares_server_default_to_avoid_sync_drift():
    docs = render(
        "charts/thirdparty/istio-config",
        "istio-config",
        "istio-system",
        values=("charts/thirdparty/istio-config/values-prod.yaml",),
    )
    gateways = [
        x
        for x in docs
        if x["kind"] == "Gateway" and x["metadata"]["name"] == "waypoint"
    ]
    assert gateways
    for gateway in gateways:
        assert gateway["spec"]["listeners"][0].get("allowedRoutes") == {
            "namespaces": {"from": "Same"}
        }


@pytest.mark.parametrize("instance", ["cache", "queue"])
def test_valkey_frontend_prefers_local_proxy_and_keeps_master_selection(instance):
    docs = render(
        "charts/apps/global-valkey",
        f"global-valkey-{instance}",
        "global",
        values=(f"charts/apps/global-valkey/values-{instance}.yaml",),
    )
    svc = next(
        x
        for x in docs
        if x["kind"] == "Service"
        and x["metadata"]["name"] == f"global-valkey-{instance}"
    )
    assert svc["spec"]["trafficDistribution"] == "PreferSameZone"
    assert svc["spec"]["selector"]["app.kubernetes.io/component"] == "haproxy"
    assert svc["spec"].get("internalTrafficPolicy", "Cluster") == "Cluster"
    config = next(
        x
        for x in docs
        if x["kind"] == "ConfigMap" and "haproxy.cfg" in x.get("data", {})
    )
    assert "role:master" in config["data"]["haproxy.cfg"]


def test_database_poolers_prefer_local_proxy_and_preserve_read_write_roles():
    docs = render("charts/apps/global-postgres", "global-postgres", "global")
    poolers = [x for x in docs if x["kind"] == "Pooler"]
    assert {x["spec"]["type"] for x in poolers} == {"rw", "ro"}
    for pooler in poolers:
        assert (
            pooler["spec"]["serviceTemplate"]["spec"]["trafficDistribution"]
            == "PreferSameZone"
        )
        assert pooler["spec"]["instances"] == 2
        assert pooler["spec"]["cluster"]["name"] == "global-postgres"
