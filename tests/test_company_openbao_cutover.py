import subprocess

import yaml
from test_homechef_openbao_access import ROOT


def test_all_ten_company_bindings_use_scoped_openbao():
    docs = []
    for chart in ("company", "console", "mark8ly-admin"):
        docs.extend(
            yaml.safe_load_all(
                subprocess.check_output(
                    ["helm", "template", chart, str(ROOT / f"charts/apps/{chart}")],
                    text=True,
                )
            )
        )
    docs.extend(
        yaml.safe_load_all(
            subprocess.check_output(
                ["kubectl", "kustomize", str(ROOT / "external-secrets/prod")], text=True
            )
        )
    )
    fields = {
        "INTERNAL_SERVICE_KEY": "tesserix-internal-service-key",
        "INTERNAL_API_TOKEN": "tesserix-internal-api-token",
        "GITHUB_TOKEN": "tesserix-github-token",
        "ONBOARDING_ADMIN_API_KEY": "tesserix-marketplace-content-admin-key",
        "ARGOCD_AUTH_TOKEN": "tesserix-argocd-auth-token",
        "SESSION_ENCRYPT_KEY": "tesserix-session-encrypt-key",
        "SENDGRID_WEBHOOK_PUBLIC_KEY": "tesserix-sendgrid-webhook-secret",
    }
    count = 0
    for doc in docs:
        if not doc or doc["kind"] != "ExternalSecret":
            continue
        name = doc["metadata"]["name"]
        if name not in (
            "company-secrets",
            "console-secrets",
            "tesserix-session",
            "tesserix-internal-api-token",
        ):
            continue
        for item in doc["spec"]["data"]:
            if item["secretKey"] not in fields:
                continue
            assert item["remoteRef"] == {
                "key": "tesserix/app/" + fields[item["secretKey"]],
                "property": "value",
            }
            assert item.get("sourceRef", {}).get(
                "storeRef", doc["spec"]["secretStoreRef"]
            ) == {"name": "openbao-tesserix-production", "kind": "SecretStore"}
            count += 1
    assert count == 10
