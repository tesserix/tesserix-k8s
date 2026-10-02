import json
from typing import Any
import pytest
from pathlib import Path
import subprocess
import sys

SCRIPT = Path(__file__).resolve().parents[1] / "drain-readiness.py"


def run_check(
    inventory: dict[str, Any], pool: str = ""
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), pool],
        input=json.dumps(inventory),
        text=True,
        capture_output=True,
    )


def test_blocks_ordinary_zero_budget_on_selected_pool() -> None:
    inventory = {
        "nodes": [
            {
                "metadata": {
                    "name": "n1",
                    "labels": {"cloud.google.com/gke-nodepool": "workers"},
                }
            }
        ],
        "pods": [
            {
                "metadata": {
                    "name": "p1",
                    "namespace": "app",
                    "labels": {"app": "api"},
                },
                "spec": {"nodeName": "n1"},
            }
        ],
        "pdbs": [
            {
                "metadata": {"name": "api", "namespace": "app"},
                "spec": {"selector": {"matchLabels": {"app": "api"}}},
                "status": {"disruptionsAllowed": 0},
            }
        ],
        "clusters": [],
    }
    result = run_check(inventory, "workers")
    assert result.returncode == 1
    assert "BLOCKED app/api" in result.stdout


def database_inventory() -> dict[str, Any]:
    owner = {
        "kind": "Cluster",
        "apiVersion": "postgresql.cnpg.io/v1",
        "uid": "db-uid",
        "name": "db",
        "controller": True,
    }
    nodes = [
        {
            "metadata": {"name": n, "labels": {"cloud.google.com/gke-nodepool": pool}},
            "status": {"conditions": [{"type": "Ready", "status": "True"}]},
        }
        for n, pool in [("n1", "workers"), ("n2", "workers"), ("n3", "other")]
    ]
    pods = [
        {
            "metadata": {
                "namespace": "db",
                "name": name,
                "labels": {"cnpg.io/cluster": "db", "role": role},
                "ownerReferences": [owner],
            },
            "spec": {"nodeName": node},
            "status": {
                "phase": "Running",
                "conditions": [{"type": "Ready", "status": "True"}],
            },
        }
        for name, node, role in [("db-1", "n1", "primary"), ("db-2", "n2", "replica")]
    ]
    pdb = {
        "metadata": {
            "name": "db-primary",
            "namespace": "db",
            "ownerReferences": [owner],
        },
        "spec": {
            "selector": {"matchLabels": {"role": "primary", "cnpg.io/cluster": "db"}}
        },
        "status": {"disruptionsAllowed": 0},
    }
    cluster = {
        "metadata": {"namespace": "db", "name": "db", "uid": "db-uid"},
        "spec": {"instances": 2},
        "status": {
            "readyInstances": 2,
            "currentPrimary": "db-1",
            "targetPrimary": "db-1",
            "phase": "Cluster in healthy state",
        },
    }
    return {"nodes": nodes, "pods": pods, "pdbs": [pdb], "clusters": [cluster]}


def test_allows_operator_managed_primary_with_healthy_distinct_standby() -> None:
    result = run_check(database_inventory(), "workers")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CNPG failover" in result.stdout


def test_ignores_pdbs_without_pods_in_selected_pool() -> None:
    assert run_check(database_inventory(), "other").returncode == 0


def test_match_expressions_exclude_unselected_pods() -> None:
    data = database_inventory()
    data["pdbs"][0]["spec"]["selector"] = {
        "matchExpressions": [{"key": "role", "operator": "In", "values": ["absent"]}]
    }
    assert run_check(data, "workers").returncode == 0


def test_null_selector_matches_nothing() -> None:
    data = database_inventory()
    data["pdbs"][0]["spec"]["selector"] = None
    assert run_check(data, "workers").returncode == 0


def test_empty_selector_matches_all_namespace_pods() -> None:
    data = database_inventory()
    data["pdbs"][0]["spec"]["selector"] = {}
    assert run_check(data, "workers").returncode == 1


@pytest.mark.parametrize(
    "unsafe",
    [
        "single",
        "same-node",
        "standby-not-ready",
        "switching",
        "wrong-owner",
        "deleting",
        "unschedulable",
        "node-not-ready",
    ],
)
def test_blocks_unsafe_cnpg_failover(unsafe: str) -> None:
    data = database_inventory()
    if unsafe == "single":
        data["clusters"][0]["spec"]["instances"] = 1
    elif unsafe == "same-node":
        data["pods"][1]["spec"]["nodeName"] = "n1"
    elif unsafe == "standby-not-ready":
        data["pods"][1]["status"]["conditions"][0]["status"] = "False"
    elif unsafe == "switching":
        data["clusters"][0]["status"]["targetPrimary"] = "db-2"
    elif unsafe == "wrong-owner":
        data["pdbs"][0]["metadata"]["ownerReferences"] = []
    elif unsafe == "deleting":
        data["pods"][1]["metadata"]["deletionTimestamp"] = "now"
    elif unsafe == "unschedulable":
        data["nodes"][1]["spec"] = {"unschedulable": True}
    elif unsafe == "node-not-ready":
        data["nodes"][1]["status"]["conditions"][0]["status"] = "False"
    assert run_check(data, "workers").returncode == 1


@pytest.mark.parametrize(
    ("operator", "key", "values", "blocked"),
    [
        ("In", "role", ["primary"], True),
        ("NotIn", "role", ["primary"], False),
        ("NotIn", "missing", ["primary"], True),
        ("Exists", "role", [], True),
        ("Exists", "missing", [], False),
        ("DoesNotExist", "missing", [], True),
        ("DoesNotExist", "role", [], False),
    ],
)
def test_selector_expression_semantics(
    operator: str, key: str, values: list[str], blocked: bool
) -> None:
    data = database_inventory()
    data["pdbs"][0]["metadata"]["ownerReferences"] = []
    data["pods"] = data["pods"][:1]
    data["pdbs"][0]["spec"]["selector"] = {
        "matchExpressions": [{"key": key, "operator": operator, "values": values}]
    }
    assert run_check(data, "workers").returncode == int(blocked)


def test_invalid_inventory_fails_closed() -> None:
    assert run_check({}).returncode == 2


def test_unknown_selector_operator_fails_closed() -> None:
    data = database_inventory()
    data["pdbs"][0]["spec"]["selector"] = {
        "matchExpressions": [{"key": "role", "operator": "unsupported"}]
    }
    assert run_check(data, "workers").returncode == 2
