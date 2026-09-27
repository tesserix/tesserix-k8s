import json
from pathlib import Path
import subprocess
import yaml
from test_homechef_openbao_access import resource

ROOT = Path(__file__).parents[1]


def render_app(app):
    source = app["spec"]["source"]
    helm = source.get("helm", {})
    chart = ROOT / source["path"]
    ns = app["spec"]["destination"]["namespace"]
    command = [
        "helm",
        "template",
        helm.get("releaseName", app["metadata"]["name"]),
        str(chart),
        "--namespace",
        ns,
    ]
    for path in helm.get("valueFiles", []):
        command += ["-f", str(chart / path)]
    command += ["-f", "-"]
    for p in helm.get("parameters", []):
        command += ["--set-string", p["name"] + "=" + p["value"]]
    rendered = list(
        yaml.safe_load_all(
            subprocess.check_output(
                command, input=yaml.safe_dump(helm.get("valuesObject", {})), text=True
            )
        )
    )
    return rendered


def test_all_reviewed_live_bindings_render_with_namespaced_openbao_sources():
    expected = json.loads((ROOT / "tests/devai-consumers.json").read_text())
    owners = {c["owner"].split(":")[0] for c in expected} - {
        "external-secrets-resources",
        "kora-secrets",
    }
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    docs += list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod/kora")],
                text=True,
            )
        )
    )
    for file in (ROOT / "argocd/prod").rglob("*.yaml"):
        app = yaml.safe_load(file.read_text())
        if (
            not isinstance(app, dict)
            or app.get("kind") != "Application"
            or app["metadata"]["name"] not in owners
        ):
            continue
        ns = app["spec"]["destination"]["namespace"]
        rendered = render_app(app)
        if app["metadata"]["name"] in {"kora-api", "kora-ai-agents"}:
            deployment = next(
                d for d in rendered if d and d.get("kind") == "Deployment"
            )
            assert (
                deployment["spec"]["template"]["metadata"]["annotations"][
                    "kora.tesserix.app/secret-source"
                ]
                == "openbao-v1"
            )
        for d in rendered:
            if d and d.get("kind") == "ExternalSecret":
                d["metadata"].setdefault("namespace", ns)
                docs.append(d)
    for c in expected:
        secret = next(
            d
            for d in docs
            if d
            and d.get("kind") == "ExternalSecret"
            and d["metadata"].get("namespace") == c["namespace"]
            and d["metadata"]["name"] == c["name"]
        )
        entry = next(d for d in secret["spec"]["data"] if d["secretKey"] == c["key"])
        import sys

        sys.path.insert(0, str(ROOT / "scripts"))
        from migrate_devai_secrets import TARGETS

        assert entry["remoteRef"] == {
            "key": TARGETS[c["source"]],
            "property": "value",
        }, c
        assert entry.get("sourceRef", {}).get(
            "storeRef", secret["spec"]["secretStoreRef"]
        ) == {"name": "openbao-devai-production", "kind": "SecretStore"}, c


def test_devai_stack_local_dependencies_match_child_versions():
    parent = ROOT / "charts/apps/devai-stack/Chart.lock"
    for dependency in yaml.safe_load(parent.read_text())["dependencies"]:
        if (
            dependency["repository"].startswith("file://")
            and dependency["version"][0].isdigit()
        ):
            child = parent.parent / dependency["repository"][7:] / "Chart.yaml"
            assert dependency["version"] == yaml.safe_load(child.read_text())["version"]


def test_devai_fresh_pods_keep_kargo_image_parameters():
    for owner, names in [
        ("devai-api", ["devai-api", "devai-api-worker"]),
        ("devai-auth-bff", ["devai-auth-bff"]),
    ]:
        app = yaml.safe_load(
            (ROOT / f"argocd/prod/apps/ai-apps/{owner}.yaml").read_text()
        )
        assert app["spec"]["source"]["helm"]["parameters"]
        docs = render_app(app)
        for name in names:
            pod = resource(docs, "Deployment", name)["spec"]["template"]
            assert (
                pod["metadata"]["annotations"]["secrets.tesserix.app/migration"]
                == "devai-openbao-20260927"
            )
