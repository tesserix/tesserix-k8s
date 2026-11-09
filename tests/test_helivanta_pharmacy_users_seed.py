"""The synthetic pharmacy bootstrap cannot overwrite or read other credentials."""

from pathlib import Path
import json
import re
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[1]
NAME = "seed-helivanta-pharmacy-users-production"
DATA = "kv/data/helivanta/production/helivanta-pharmacy-seed-users"


def configuration():
    return yaml.safe_load((ROOT / "charts/thirdparty/openbao/values.yaml").read_text())["bootstrap"]


def test_seed_can_create_once_and_read_only_its_exact_record():
    config = configuration()
    policy = next(item for item in config["policies"] if item["name"] == NAME)
    rules = {
        path: set(re.findall(r'"([a-z-]+)"', capabilities))
        for path, capabilities in re.findall(
            r'path "([^"]+)"\s*\{\s*capabilities\s*=\s*\[([^\]]+)\]\s*\}', policy["hcl"]
        )
    }
    assert rules == {
        DATA: {"create", "read"},
        DATA.replace("/data/", "/metadata/"): {"read"},
        "auth/token/revoke-self": {"update"},
        "sys/capabilities-self": {"update"},
    }
    assert all("*" not in path and "+" not in path for path in rules)
    assert not ({"update", "delete", "list", "sudo"} & rules[DATA])


def test_seed_uses_only_the_existing_bootstrap_identity_and_five_minute_lease():
    config = configuration()
    role = next(item for item in config["kubernetesRoles"] if item["name"] == NAME)
    assert role["serviceAccounts"] == ["helivanta-pharmacy-evidence-secret-seed"]
    assert role["namespaces"] == ["helivanta"]
    assert role["policies"] == [NAME]
    assert role["audience"] == "openbao"
    assert role["ttl"] == role["maxTTL"] == "5m"
    template = (ROOT / "charts/thirdparty/openbao/templates/bootstrap-configmap.yaml").read_text()
    assert 'set $role "token_max_ttl" .maxTTL' in template


def test_rendered_role_caps_the_actual_server_token_lifetime():
    rendered = subprocess.check_output([
        "helm", "template", "seed-test", "charts/thirdparty/openbao",
        "--set", "bootstrap.enabled=true", "--show-only", "templates/bootstrap-configmap.yaml",
    ], cwd=ROOT, text=True)
    config = next(doc for doc in yaml.safe_load_all(rendered) if doc and doc["kind"] == "ConfigMap")
    role = json.loads(config["data"]["role-" + NAME + ".json"])
    assert role == {
        "bound_service_account_names": ["helivanta-pharmacy-evidence-secret-seed"],
        "bound_service_account_namespaces": ["helivanta"],
        "token_policies": [NAME],
        "audience": "openbao",
        "token_ttl": "5m",
        "token_max_ttl": "5m",
    }
