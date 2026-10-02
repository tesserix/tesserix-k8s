#!/usr/bin/env python3
"""Evaluate disruption budgets against pods on the nodes being upgraded."""

import json
import sys
import subprocess
from typing import Any


def matches(labels: dict[str, str], selector: dict[str, Any] | None) -> bool:
    if selector is None:
        return False
    if not all(labels.get(k) == v for k, v in selector.get("matchLabels", {}).items()):
        return False
    for expression in selector.get("matchExpressions", []):
        key, operator = expression["key"], expression["operator"]
        values = expression.get("values", [])
        if operator == "In":
            valid = key in labels and labels[key] in values
        elif operator == "NotIn":
            valid = key not in labels or labels[key] not in values
        elif operator == "Exists":
            valid = key in labels
        elif operator == "DoesNotExist":
            valid = key not in labels
        else:
            raise ValueError(f"Unsupported selector operator: {operator}")
        if not valid:
            return False
    return True


def ready(resource: dict[str, Any]) -> bool:
    return any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in resource.get("status", {}).get("conditions", [])
    )


def owned_by(resource: dict[str, Any], uid: str) -> bool:
    return any(
        o.get("uid") == uid
        and o.get("kind") == "Cluster"
        and o.get("apiVersion") == "postgresql.cnpg.io/v1"
        and o.get("controller") is True
        for o in resource["metadata"].get("ownerReferences", [])
    )


def cnpg_failover(
    pdb: dict[str, Any], selected: list[dict[str, Any]], inventory: dict[str, Any]
) -> bool:
    namespace = pdb["metadata"]["namespace"]
    for cluster in inventory["clusters"]:
        meta, status = cluster["metadata"], cluster.get("status", {})
        if meta["namespace"] != namespace or not owned_by(pdb, meta["uid"]):
            continue
        primary = status.get("currentPrimary")
        desired = cluster["spec"]["instances"]
        if (
            desired < 2
            or status.get("readyInstances", 0) < desired
            or status.get("phase") != "Cluster in healthy state"
            or not primary
            or status.get("targetPrimary") != primary
            or len(selected) != 1
            or selected[0]["metadata"]["name"] != primary
            or not owned_by(selected[0], meta["uid"])
            or not ready(selected[0])
        ):
            return False
        primary_node = selected[0]["spec"]["nodeName"]
        healthy_nodes = {
            n["metadata"]["name"]
            for n in inventory["nodes"]
            if ready(n) and not n.get("spec", {}).get("unschedulable", False)
        }
        for pod in inventory["pods"]:
            if (
                pod["metadata"]["namespace"] == namespace
                and owned_by(pod, meta["uid"])
                and pod["metadata"]["name"] != primary
                and not pod["metadata"].get("deletionTimestamp")
                and pod.get("status", {}).get("phase") == "Running"
                and ready(pod)
                and pod.get("spec", {}).get("nodeName") in healthy_nodes
                and pod["spec"]["nodeName"] != primary_node
            ):
                return True
    return False


def blockers(inventory: dict[str, Any], pool: str) -> list[str]:
    nodes = {
        n["metadata"]["name"]
        for n in inventory["nodes"]
        if not pool
        or n["metadata"].get("labels", {}).get("cloud.google.com/gke-nodepool") == pool
    }
    blocked = []
    for pdb in inventory["pdbs"]:
        if pdb.get("status", {}).get("disruptionsAllowed", 0) > 0:
            continue
        namespace = pdb["metadata"]["namespace"]
        selector = pdb["spec"].get("selector")
        selected = [
            p
            for p in inventory["pods"]
            if p["metadata"]["namespace"] == namespace
            and p.get("spec", {}).get("nodeName") in nodes
            and p.get("status", {}).get("phase") not in ("Succeeded", "Failed")
            and matches(p["metadata"].get("labels", {}), selector)
        ]
        if selected and cnpg_failover(pdb, selected, inventory):
            print(f"CNPG failover ready: {namespace}/{pdb['metadata']['name']}")
        elif selected:
            blocked.append(f"{namespace}/{pdb['metadata']['name']}")
    return blocked


if __name__ == "__main__":
    try:
        if "--live" in sys.argv:
            inventory = {}
            for key, resource in [
                ("pods", "pods"),
                ("nodes", "nodes"),
                ("pdbs", "pdb"),
                ("clusters", "clusters.postgresql.cnpg.io"),
            ]:
                inventory[key] = json.loads(
                    subprocess.check_output(
                        ["kubectl", "get", resource, "-A", "-o", "json"]
                    )
                )["items"]
        else:
            inventory = json.load(sys.stdin)
        found = blockers(inventory, sys.argv[1] if len(sys.argv) > 1 else "")
        for name in found:
            print(f"BLOCKED {name}")
        sys.exit(1 if found else 0)
    except (ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"Invalid drain inventory: {error}", file=sys.stderr)
        sys.exit(2)
