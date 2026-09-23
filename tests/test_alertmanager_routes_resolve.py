"""Every secret an AlertmanagerConfig references must actually be created.

An AlertmanagerConfig is all-or-nothing. One unresolvable secret reference
does not disable one receiver — the prometheus-operator rejects the whole
object, and every route in it silently stops existing:

    AlertmanagerConfig subscription-routes was rejected due to invalid
    configuration: unable to get secret "slack-webhooks": secrets
    "slack-webhooks" not found

That is what happened here for 19 days. The file declared a severity
fan-out, a security branch and two PagerDuty paths; none of them ever
loaded, and what looked from the outside like a policy of discarding
severity=warning was simply this object never being admitted.

The object stays schema-valid the whole time, so `kubectl apply
--dry-run=server` passes and tells you nothing. The property worth testing
is the one the operator actually checks at admission: does something in this
repo create every secret named here?
"""

from pathlib import Path

import yaml


ROOT = Path(__file__).parents[1]
ROUTES = ROOT / "k8s/cluster/alertmanager/routes.yaml"
EXTERNAL_SECRETS = ROOT / "external-secrets/prod"


def _secret_refs(node, found):
    """Collect (secret name, key) from every LocalObjectReference-ish dict."""
    if isinstance(node, dict):
        # apiURL / routingKey / any {name, key} pair naming a Secret.
        if set(node) == {"name", "key"}:
            found.add((node["name"], node["key"]))
        for value in node.values():
            _secret_refs(value, found)
    elif isinstance(node, list):
        for item in node:
            _secret_refs(item, found)
    return found


def _provisioned_secrets():
    """Map secret name -> set of keys, from the ExternalSecrets in the repo."""
    provisioned = {}
    for path in EXTERNAL_SECRETS.rglob("*.yaml"):
        for doc in yaml.safe_load_all(path.read_text()):
            if not doc or doc.get("kind") != "ExternalSecret":
                continue
            spec = doc.get("spec", {})
            name = spec.get("target", {}).get("name") or doc["metadata"]["name"]
            keys = {
                entry["secretKey"]
                for entry in spec.get("data", [])
                if "secretKey" in entry
            }
            provisioned.setdefault(name, set()).update(keys)
    return provisioned


def test_every_referenced_secret_is_provisioned_somewhere_in_this_repo():
    config = yaml.safe_load(ROUTES.read_text())
    assert config["kind"] == "AlertmanagerConfig"

    referenced = _secret_refs(config["spec"], set())
    assert referenced, "no secret references found — did the schema change?"

    provisioned = _provisioned_secrets()

    missing = [
        f"{name}/{key}"
        for name, key in sorted(referenced)
        if key not in provisioned.get(name, set())
    ]
    assert not missing, (
        "AlertmanagerConfig references secrets nothing in this repo creates: "
        f"{missing}. The operator rejects the ENTIRE object for one of these, "
        "so every route in the file stops existing — silently."
    )


def test_the_secret_lives_in_the_same_namespace_as_the_config():
    """A Secret ref in an AlertmanagerConfig is namespace-local."""
    config = yaml.safe_load(ROUTES.read_text())
    namespace = config["metadata"]["namespace"]

    names = {name for name, _ in _secret_refs(config["spec"], set())}
    for path in EXTERNAL_SECRETS.rglob("*.yaml"):
        for doc in yaml.safe_load_all(path.read_text()):
            if not doc or doc.get("kind") != "ExternalSecret":
                continue
            target = doc["spec"].get("target", {}).get("name")
            if target in names:
                assert doc["metadata"]["namespace"] == namespace, (
                    f"{target} is created in {doc['metadata']['namespace']} but "
                    f"referenced from an AlertmanagerConfig in {namespace}; "
                    "secret refs there do not cross namespaces"
                )
