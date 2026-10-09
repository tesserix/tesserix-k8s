import subprocess
from pathlib import Path

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[1]


def render_application(name, tmp_path, *, parked=True):
    app = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure" / f"{name}.yaml").read_text()
    )
    source = app["spec"]["source"]
    helm = source["helm"]
    chart = ROOT / source["path"]
    command = [
        "helm", "template", helm["releaseName"], str(chart),
        "--namespace", app["spec"]["destination"]["namespace"],
    ]
    for value_file in helm.get("valueFiles", []):
        command.extend(["-f", str(chart / value_file)])
    if helm.get("values"):
        values = tmp_path / f"{name}-values.yaml"
        values.write_text(helm["values"])
        command.extend(["-f", str(values)])
    if parked:
        for parameter in helm.get("parameters", []):
            flag = "--set-string" if parameter.get("forceString") else "--set"
            command.extend([flag, f"{parameter['name']}={parameter['value']}"])
    output = subprocess.run(command, check=True, capture_output=True, text=True)
    return [item for item in yaml.safe_load_all(output.stdout) if item]


@pytest.mark.parametrize("name", [
    "redpanda", "otel-gateway",
])
def test_retired_park_has_no_explicit_claims_to_recreate_disks(name, tmp_path):
    items = render_application(name, tmp_path)
    assert not any(item["kind"] == "PersistentVolumeClaim" for item in items)
    assert all(
        item["spec"]["replicas"] == 0
        for item in items if item["kind"] == "StatefulSet"
    )


@pytest.mark.parametrize("name", [
    "clickhouse-ha", "clickhouse-keeper", "redpanda", "otel-gateway",
    "otel-ingest", "otel-cluster", "obs-api", "obs-ui", "opencost",
])
def test_park_stops_workloads_without_pruning_retained_resources(name, tmp_path):
    active = render_application(name, tmp_path, parked=False)
    parked = render_application(name, tmp_path)
    def identities(items):
        return {
            (item["kind"], item["metadata"]["name"]) for item in items
            if not item["metadata"].get("annotations", {}).get("argocd.argoproj.io/hook")
            and not (
                name in {"redpanda", "otel-gateway"}
                and item["kind"] == "PersistentVolumeClaim"
            )
        }
    assert identities(parked) == identities(active)
    workloads = [
        item for item in parked if item["kind"] in {"Deployment", "StatefulSet"}
    ]
    assert workloads
    assert all(item["spec"]["replicas"] == 0 for item in workloads)
    for item in workloads:
        retention = item["spec"].get("persistentVolumeClaimRetentionPolicy", {})
        assert retention.get("whenScaled", "Retain") == "Retain"
        assert retention.get("whenDeleted", "Retain") == "Retain"


def test_agent_park_cannot_schedule_on_normal_nodes_and_keeps_daemonset(tmp_path):
    items = render_application("otel-agent", tmp_path)
    agent = next(item for item in items if item["kind"] == "DaemonSet")
    selector = agent["spec"]["template"]["spec"].get("nodeSelector", {})
    for node in [{}, {"workload": "infrastructure"}, {"workload": "observability"}]:
        assert any(node.get(key) != value for key, value in selector.items())
    assert any(item["kind"] == "ConfigMap" for item in items)


def test_park_suspends_schema_reconciliation_without_deleting_cronjob(tmp_path):
    items = render_application("observability-db-schema-bootstrap", tmp_path)
    jobs = [item for item in items if item["kind"] == "CronJob"]
    assert jobs
    assert all(item["spec"]["suspend"] is True for item in jobs)
