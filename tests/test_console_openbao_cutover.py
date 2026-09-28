import subprocess

import yaml
from test_console_openbao_access import TARGETS
from test_homechef_openbao_access import ROOT, resource


def test_production_console_uses_twelve_scoped_paths_and_shared_session():
    chart = ROOT / "charts/apps/console"
    docs = list(
        yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "console",
                    str(chart),
                    "--namespace",
                    "tesserix",
                    "-f",
                    str(chart / "values-prod.yaml"),
                ],
                text=True,
            )
        )
    )
    spec = resource(docs, "ExternalSecret", "console-secrets")["spec"]
    assert spec["secretStoreRef"] == {
        "kind": "SecretStore",
        "name": "openbao-console-production",
    }
    assert len(spec["data"]) == 13
    assert {d["remoteRef"]["key"] for d in spec["data"]} == set(TARGETS.values()) | {
        "tesserix/app/tesserix-session-encrypt-key"
    }
    assert all(d["remoteRef"]["property"] == "value" for d in spec["data"])
    session = next(d for d in spec["data"] if d["secretKey"] == "SESSION_ENCRYPT_KEY")
    assert session["sourceRef"]["storeRef"] == {
        "kind": "SecretStore",
        "name": "openbao-tesserix-production",
    }
    assert all(
        d.get("sourceRef", {}).get("storeRef", spec["secretStoreRef"])
        == spec["secretStoreRef"]
        for d in spec["data"]
        if d != session
    )
