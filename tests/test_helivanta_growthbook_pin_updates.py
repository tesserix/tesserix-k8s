from pathlib import Path

import json
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_kargo_scalar_updates_cannot_truncate_inline_parameter_mappings():
    source = (ROOT / "argocd/prod/apps/helivanta/helivanta-growthbook.yaml").read_text()
    document = yaml.compose(source)
    def field(node, name):
        return next(value for key, value in node.value if key.value == name)
    parameters = field(field(field(field(document, "spec"), "source"), "helm"), "parameters")
    assert len(parameters.value) == 2
    for parameter in parameters.value:
        assert not parameter.flow_style, "Kargo yaml-update replaces scalar lines; use block mappings"
        assert field(parameter, "forceString").value == "true"


def test_parent_reconciles_growthbook_pins_and_preserves_workload_overrides():
    parent = yaml.safe_load((ROOT / "argocd/prod/apps/helivanta-app-of-apps.yaml").read_text())
    rules = parent["spec"]["ignoreDifferences"]
    for name in ("helivanta-growthbook", "helivanta-api", "helivanta-global-api", "helivanta-shell"):
        app = {"metadata": {"name": name}, "spec": {"source": {"helm": {"parameters": [{"name": "image.tag", "value": "promoted"}]}}}}
        ignored = False
        for rule in rules:
            if rule.get("name", name) != name:
                continue
            ignored |= "/spec/source/helm/parameters" in rule.get("jsonPointers", [])
            for expression in rule.get("jqPathExpressions", []):
                result = subprocess.run(["jq", "-c", expression], input=json.dumps(app), text=True, capture_output=True, check=True)
                ignored |= bool(result.stdout.strip())
        assert ignored == (name != "helivanta-growthbook"), name
