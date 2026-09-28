import subprocess

import yaml
from test_homechef_openbao_access import ROOT, resource


def test_token_and_optional_slack_use_openbao_values():
    for overrides, count in [([], 1), (["--set", "slack.clientID=synthetic"], 3)]:
        docs = [
            doc
            for doc in yaml.safe_load_all(
                subprocess.check_output(
                    [
                        "helm",
                        "template",
                        "planning-poker",
                        str(ROOT / "charts/apps/planning-poker"),
                        *overrides,
                    ],
                    text=True,
                )
            )
            if doc
        ]
        secret = resource(docs, "ExternalSecret", "planning-poker-api")["spec"]
        assert secret["secretStoreRef"] == {
            "kind": "SecretStore",
            "name": "openbao-planning-poker-production",
        }
        assert len(secret["data"]) == count
        for item in secret["data"]:
            assert item["remoteRef"]["property"] == "value"
            assert item["remoteRef"]["key"].startswith(
                "planning-poker/app/planning-poker-"
            )
