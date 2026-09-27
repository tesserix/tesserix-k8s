from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).parents[1]


def render_application(name):
    app = yaml.safe_load((ROOT / f"argocd/prod/apps/blog/{name}.yaml").read_text())
    source = app["spec"]["source"]
    command = ["helm", "template", name, str(ROOT / source["path"])]
    for path in source["helm"].get("valueFiles", []):
        command += ["-f", str(ROOT / source["path"] / path)]
    for parameter in source["helm"].get("parameters", []):
        command += ["--set-string", parameter["name"] + "=" + parameter["value"]]
    return [
        d
        for d in yaml.safe_load_all(
            subprocess.check_output(
                command + ["-f", "-"],
                input=yaml.safe_dump(source["helm"].get("valuesObject", {})),
                text=True,
            )
        )
        if d
    ]


def test_production_blog_and_database_use_openbao_with_unchanged_kubernetes_keys():
    app = render_application("tesserix-blog")
    entries = {
        item["secretKey"]: item
        for d in app
        if d["kind"] == "ExternalSecret"
        for item in d["spec"]["data"]
    }
    for key, suffix in {
        "MONGODB_URI": "mongodb-uri",
        "SESSION_SECRET": "session-secret",
        "OIDC_CLIENT_SECRET": "oidc-client-secret",
    }.items():
        assert entries[key]["remoteRef"] == {
            "key": "blog/app/blog-" + suffix,
            "property": "value",
        }
    assert (
        entries["RESEND_API_KEY"]["remoteRef"]["key"]
        == "homechef/homechef-api/fe3dr-resend-api-key"
    )
    for d in app:
        if d["kind"] == "ExternalSecret":
            assert d["spec"]["secretStoreRef"] == {
                "name": "openbao-blog-production",
                "kind": "SecretStore",
            }
    db = render_application("mongodb-blog")
    secret = next(d for d in db if d["kind"] == "ExternalSecret")
    assert secret["spec"]["data"] == [
        {
            "secretKey": "MONGO_ROOT_PASSWORD",
            "remoteRef": {
                "key": "blog/app/blog-mongodb-root-password",
                "property": "value",
            },
        }
    ]
    statefulset = next(d for d in db if d["kind"] == "StatefulSet")
    assert (
        statefulset["spec"]["volumeClaimTemplates"][0]["spec"]["storageClassName"]
        == "standard"
    )
    assert (
        statefulset["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"][
            "storage"
        ]
        == "120Gi"
    )


def test_blog_backup_and_legacy_readers_have_no_remaining_gcp_dependency():
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    for namespace, name, key, suffix, store in [
        (
            "db-backup-and-restore",
            "mongodb-blog-password",
            "mongodb-password",
            "mongodb-root-password",
            "openbao-blog-production",
        ),
        (
            "tesserix",
            "blog-identity-bootstrap-client-secrets",
            "blog-bff-secret",
            "keycloak-client-secret",
            "openbao-blog-legacy",
        ),
    ]:
        secret = next(
            d
            for d in docs
            if d
            and d["kind"] == "ExternalSecret"
            and d["metadata"]["name"] == name
            and d["metadata"]["namespace"] == namespace
        )
        assert secret["spec"]["secretStoreRef"] == {
            "name": store,
            "kind": "SecretStore",
        }
        assert secret["spec"]["data"] == [
            {
                "secretKey": key,
                "remoteRef": {"key": "blog/app/blog-" + suffix, "property": "value"},
            }
        ]


def test_unmigrated_environment_keeps_its_gcp_source_prefix():
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "blog",
                    str(ROOT / "charts/apps/tesserix-blog"),
                    "--set",
                    "gcp.secretManager.secretPrefix=dev",
                ],
                text=True,
            )
        )
    )
    for doc in docs:
        if not doc or doc["kind"] != "ExternalSecret":
            continue
        assert doc["spec"]["secretStoreRef"] == {
            "name": "gcp-secret-store",
            "kind": "ClusterSecretStore",
        }
        for entry in doc["spec"]["data"]:
            if entry["secretKey"] != "RESEND_API_KEY":
                assert entry["remoteRef"]["key"].startswith("dev-blog-")


def test_cutover_settings_are_not_hidden_by_kargo_parameter_ignores():
    parent = yaml.safe_load(
        (ROOT / "argocd/prod/apps/blog-app-of-apps.yaml").read_text()
    )
    assert (
        "/spec/source/helm/parameters"
        in parent["spec"]["ignoreDifferences"][0]["jsonPointers"]
    )
    for name in ["tesserix-blog", "mongodb-blog"]:
        app = yaml.safe_load((ROOT / f"argocd/prod/apps/blog/{name}.yaml").read_text())
        helm = app["spec"]["source"]["helm"]
        assert helm.get("valuesObject", {}).get("externalSecrets") == {
            "provider": "openbao",
            "secretStoreRef": "openbao-blog-production",
        }
