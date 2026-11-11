import json
import re
import subprocess

import yaml
from test_homechef_openbao_access import ROOT, render, resource

SECRET = "kv/data/helivanta/prod/app/helivanta-onboarding-resend-api-key"


def test_mail_access_is_limited_to_one_key_and_namespace():
    config = resource(
        render("charts/thirdparty/openbao"), "ConfigMap", "openbao-bootstrap"
    )["data"]
    for mode, capabilities in [
        ("writer", '"create", "read", "update"'),
        ("reader", '"read"'),
    ]:
        name = f"helivanta-onboarding-email-{mode}"
        policy = config[f"policy-{name}.hcl"]
        paths = re.findall(r'path "([^"]+)"', policy)
        assert paths == (
            [SECRET, "auth/token/revoke-self"] if mode == "writer" else [SECRET]
        )
        assert re.findall(r"capabilities = \[([^]]+)\]", policy)[0] == capabilities
        assert "*" not in policy
        role = json.loads(config[f"role-{name}.json"])
        assert role["bound_service_account_names"] == [name]
        assert role["bound_service_account_namespaces"] == ["onboarding"]
        assert role["token_policies"] == [name]
        assert role["token_ttl"] == "5m"
        assert role["token_max_ttl"] == "5m"
        assert role["audience"] == "vault"


def onboarding_documents(production):
    args = [
        "helm",
        "template",
        "onboarding-service",
        str(ROOT / "charts/apps/onboarding-service"),
    ]
    if production:
        args += ["-f", str(ROOT / "charts/apps/onboarding-service/values-prod.yaml")]
    return [
        doc
        for doc in yaml.safe_load_all(subprocess.check_output(args, text=True))
        if doc
    ]


def test_production_mail_accounts_never_automount_credentials():
    documents = onboarding_documents(True)
    for mode in ["writer", "reader"]:
        account = resource(
            documents, "ServiceAccount", f"helivanta-onboarding-email-{mode}"
        )
        assert account["metadata"]["namespace"] == "onboarding"
        assert account["automountServiceAccountToken"] is False
    for document in documents:
        if document["kind"] == "Deployment":
            assert document["spec"]["template"]["spec"]["serviceAccountName"] not in [
                "helivanta-onboarding-email-writer",
                "helivanta-onboarding-email-reader",
            ]


def test_mail_access_is_opt_in_and_does_not_activate_delivery():
    assert not any(
        d["metadata"]["name"].startswith("helivanta-onboarding-email-")
        for d in onboarding_documents(False)
    )
    documents = onboarding_documents(True)
    api = resource(documents, "Deployment", "onboarding-api")
    assert "HELIVANTA_EMAIL_FROM" not in json.dumps(api)
