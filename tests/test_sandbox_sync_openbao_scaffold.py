import importlib.util
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location(
    "scaffold", ROOT / "scripts/scaffold-sandbox-sync.py"
)
scaffold = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scaffold)


def test_scaffold_generates_namespaced_reader_and_four_product_paths():
    text = scaffold.externalsecrets_yaml("homechef", "homechef-sandbox-sync")
    docs = list(yaml.safe_load_all(text))
    store = next(d for d in docs if d["kind"] == "SecretStore")
    account = next(d for d in docs if d["kind"] == "ServiceAccount")
    assert account["automountServiceAccountToken"] is False
    assert all(d["metadata"]["namespace"] == "homechef" for d in docs)
    vault = store["spec"]["provider"]["vault"]
    assert vault["path"] == "kv" and vault["version"] == "v2"
    auth = vault["auth"]["kubernetes"]
    assert auth["serviceAccountRef"]["name"] == account["metadata"]["name"]
    assert auth["role"] == "read-homechef-sandbox-sync"
    paths = set()
    for d in docs:
        if d["kind"] != "ExternalSecret":
            continue
        assert d["spec"]["secretStoreRef"] == {
            "name": store["metadata"]["name"],
            "kind": "SecretStore",
        }
        for item in d["spec"]["data"]:
            assert item["remoteRef"]["property"] == "value"
            paths.add(item["remoteRef"]["key"])
    assert paths == {
        "homechef/sandbox-sync/fe3dr-" + suffix
        for suffix in (
            "sandbox-reader-password",
            "sandbox-sync-source-url",
            "sandbox-sync-target-url",
            "sandbox-anonymization-salt",
        )
    }
    assert "gcp-secret-store" not in text


@pytest.mark.parametrize(
    "namespace", ["../other", "valid\nkind: Secret", "", "Capital", "x" * 64]
)
def test_scaffold_rejects_invalid_namespace(namespace):
    with pytest.raises(ValueError):
        scaffold.externalsecrets_yaml(namespace, "sync")


def test_development_paths_cannot_overlap_production():
    def paths(namespace):
        docs = yaml.safe_load_all(
            scaffold.externalsecrets_yaml(namespace, "sandbox-sync")
        )
        return {
            item["remoteRef"]["key"]
            for d in docs
            if d["kind"] == "ExternalSecret"
            for item in d["spec"]["data"]
        }

    prod, dev = paths("homechef"), paths("homechef-development")
    assert not prod & dev
    assert all(
        path.startswith("homechef-development/sandbox-sync/fe3dr-") for path in dev
    )


def test_main_prints_exact_readonly_bootstrap_and_no_gcp_provisioning(
    tmp_path, monkeypatch, capsys
):
    claim_dir = tmp_path / "claims"
    claim_dir.mkdir()
    claim_path = claim_dir / "sample.yaml"
    claim_path.write_text(
        yaml.safe_dump(
            {
                "kind": "SandboxDataSync",
                "metadata": {"namespace": "sample"},
                "spec": {
                    "source": {"secretRef": {"name": "sample-sync"}},
                    "tables": [
                        {"target": "sample.events", "columns": [{"name": "id"}]}
                    ],
                },
            }
        )
    )
    sql = tmp_path / "schema.sql"
    sql.write_text("")
    monkeypatch.setattr(scaffold, "ROOT", tmp_path)
    monkeypatch.setattr(scaffold, "EVALS_SQL", sql)
    monkeypatch.setattr(scaffold.sys, "argv", ["scaffold", str(claim_path)])
    monkeypatch.setattr(scaffold.subprocess, "run", lambda *a, **kw: None)
    scaffold.main()
    output = capsys.readouterr().out
    assert "gcloud secrets" not in output
    bootstrap = yaml.safe_load("bootstrap:\n" + output.split("bootstrap:\n", 1)[1])[
        "bootstrap"
    ]
    assert 'capabilities = ["read"]' in bootstrap["policies"][0]["hcl"]
    assert "read-sample-sandbox-sync" in output
    assert "sample/sandbox-sync/sample-sandbox-reader-password" in output
    assert (tmp_path / "external-secrets/prod/sample/sandbox-sync.yaml").exists()
