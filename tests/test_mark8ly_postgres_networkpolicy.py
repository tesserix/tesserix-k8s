"""Every ingress rule into the mark8ly CNPG pods must permit HBONE (15008).

The namespace runs in Istio ambient mode, so ztunnel never connects to the
application port directly: it tunnels the connection to the pod on 15008 and
only unwraps it to 5432/9187 inside the pod. A rule that names just the
application port therefore allows a port the packet never uses, and the
connection dies at ztunnel with

    connection timed out, maybe a NetworkPolicy is blocking HBONE port 15008

That failure is silent in exactly the wrong way — the exporter keeps serving
200s to anything on the pod's own node, so the pod looks healthy while every
scrape times out. It has now been hit twice: once when the namespace moved to
ambient (app pods could not reach 5432), and once on the monitoring rule,
which left the CNPG metrics unscrapeable and two CNPG alerts evaluating over
a series that was never ingested.
"""

from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]

HBONE_PORT = 15008
# Ports that ambient wraps. 8000 is the CNPG instance-manager status port,
# which the operator reaches over the mesh like anything else.
TUNNELLED_PORTS = {5432, 9187, 8000}


def render():
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "mark8ly-postgres",
            str(ROOT / "charts/apps/mark8ly-postgres"),
            "--namespace",
            "mark8ly",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [document for document in yaml.safe_load_all(rendered) if document]


def postgres_ingress():
    return next(
        document
        for document in render()
        if document.get("kind") == "NetworkPolicy"
        and document.get("metadata", {}).get("name", "").endswith("-ingress")
    )


def test_every_tunnelled_rule_also_allows_hbone():
    offenders = []
    for index, rule in enumerate(postgres_ingress()["spec"]["ingress"]):
        ports = {entry["port"] for entry in rule.get("ports", [])}
        if ports & TUNNELLED_PORTS and HBONE_PORT not in ports:
            offenders.append((index, sorted(ports)))
    assert not offenders, (
        "ingress rules allow an ambient-tunnelled port without HBONE "
        f"{HBONE_PORT}, so ztunnel cannot deliver to them: {offenders}"
    )


def test_prometheus_can_scrape_cnpg_metrics():
    """The regression this file exists for: monitoring reaching 9187."""
    for rule in postgres_ingress()["spec"]["ingress"]:
        namespaces = {
            peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
            for peer in rule.get("from", [])
            if "namespaceSelector" in peer
        }
        if "monitoring" not in namespaces:
            continue
        ports = {entry["port"] for entry in rule.get("ports", [])}
        assert {9187, HBONE_PORT} <= ports, (
            f"monitoring rule allows {sorted(ports)}; Prometheus is in the mesh "
            f"so its scrape arrives on {HBONE_PORT}, not 9187"
        )
        return
    raise AssertionError("no ingress rule admits the monitoring namespace")
