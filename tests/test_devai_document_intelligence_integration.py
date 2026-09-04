import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
EXTERNAL_SECRETS = ROOT / "external-secrets/prod/devai/externalsecret.yaml"
DEVAI_HELPERS = ROOT / "charts/apps/devai-api/templates/_helpers.tpl"
DEVAI_PROD_VALUES = ROOT / "charts/apps/devai-api/values-prod.yaml"
DEVAI_POLICY = ROOT / "manifests/devai-istio/network-policy.yaml"
TFVARS = ROOT / "terraform-new/environments/prod/terraform.tfvars"


def test_devai_uses_a_kora_dev_only_ocr_signing_key_and_sandbox_endpoint() -> None:
    resources = [item for item in yaml.safe_load_all(EXTERNAL_SECRETS.read_text()) if item]
    secret = next(item for item in resources if item["metadata"]["name"] == "devai-document-intelligence-kora-dev")

    assert secret["spec"]["target"]["name"] == "devai-document-intelligence-kora-dev"
    assert secret["spec"]["data"] == [
        {
            "secretKey": "DEVAI_DOCUMENT_INTELLIGENCE_SIGNING_KEY",
            "remoteRef": {"key": "dev-kora-document-intelligence-signing-key"},
        }
    ]
    helpers = DEVAI_HELPERS.read_text()
    assert "DEVAI_DOCUMENT_INTELLIGENCE_SIGNING_KEY" in helpers
    assert "devai-document-intelligence-kora-dev" in helpers

    values = yaml.safe_load(DEVAI_PROD_VALUES.read_text())
    assert values["env"]["DEVAI_DOCUMENT_INTELLIGENCE_SERVICE_URL"] == (
        "http://document-intelligence-sandbox-upload-api.document-intelligence.svc.cluster.local:8080"
    )
    assert values["env"]["DEVAI_DOCUMENT_INTELLIGENCE_JOB_SERVICE_URL"] == (
        "http://document-intelligence-sandbox-job-api.document-intelligence.svc.cluster.local:8080"
    )
    assert values["env"]["DEVAI_DOCUMENT_INTELLIGENCE_KEY_ID"] == "kora-dev-v1"
    assert values["podAnnotations"]["secret.reloader.stakater.com/reload"] == (
        "devai-langfuse-secrets,devai-document-intelligence-kora-dev"
    )


def test_devai_direct_ocr_egress_is_limited_to_the_sandbox_namespace() -> None:
    resources = [item for item in yaml.safe_load_all(DEVAI_POLICY.read_text()) if item]
    policy = next(item for item in resources if item["metadata"]["name"] == "devai-api-netpol")

    assert {
        "to": [
            {
                "namespaceSelector": {
                    "matchLabels": {"kubernetes.io/metadata.name": "document-intelligence"}
                }
            }
        ],
        "ports": [{"port": 8080, "protocol": "TCP"}],
    } in policy["spec"]["egress"]


def test_kora_dev_signing_secret_is_declared_without_secret_material() -> None:
    configuration = TFVARS.read_text()
    match = re.search(
        r'secret_id\s*=\s*"dev-kora-document-intelligence-signing-key"(?P<body>[^}]*)}',
        configuration,
        re.DOTALL,
    )

    assert match is not None
    assert 'environment = "dev"' in match.group(0)
    assert "secret_data" not in match.group(0)
