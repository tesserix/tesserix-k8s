import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).parents[1]


def test_support_platform_readers_are_in_the_live_gitops_resource_tree():
    result = subprocess.run(
        ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")],
        check=True,
        capture_output=True,
        text=True,
    )
    resources = {
        (d["kind"], d["metadata"].get("namespace"), d["metadata"]["name"])
        for d in yaml.safe_load_all(result.stdout)
        if d
    }
    for ns in ["support-platform", "agentgateway-system"]:
        assert ("ServiceAccount", ns, "support-platform-production-reader") in resources
        assert ("SecretStore", ns, "openbao-support-platform-production") in resources
