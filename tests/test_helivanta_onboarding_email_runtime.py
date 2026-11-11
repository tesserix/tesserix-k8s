import subprocess

import yaml
from test_homechef_openbao_access import ROOT, resource


def documents(enabled=False):
    chart = ROOT / "charts/apps/onboarding-service"
    args = [
        "helm",
        "template",
        "onboarding-service",
        str(chart),
        "-f",
        str(chart / "values-prod.yaml"),
    ]
    if enabled:
        args += [
            "--set",
            "helivantaEmail.enabled=true",
            "--set",
            "helivantaEmail.from=onboarding@helivanta.app",
        ]
    return [
        doc
        for doc in yaml.safe_load_all(subprocess.check_output(args, text=True))
        if doc
    ]


def test_product_secret_uses_exact_namespace_reader_and_property():
    docs = documents()
    store = resource(docs, "SecretStore", "helivanta-onboarding-email")
    assert store["metadata"]["namespace"] == "onboarding"
    vault = store["spec"]["provider"]["vault"]
    assert vault["path"] == "kv"
    assert vault["version"] == "v2"
    assert vault["auth"]["kubernetes"] == {
        "mountPath": "kubernetes",
        "role": "helivanta-onboarding-email-reader",
        "serviceAccountRef": {
            "name": "helivanta-onboarding-email-reader",
            "audiences": ["vault"],
        },
    }
    secret = resource(docs, "ExternalSecret", "onboarding-helivanta-resend")
    assert secret["spec"]["secretStoreRef"] == {
        "name": "helivanta-onboarding-email",
        "kind": "SecretStore",
    }
    assert secret["spec"]["data"] == [
        {
            "secretKey": "api-key",
            "remoteRef": {
                "key": "helivanta/prod/app/helivanta-onboarding-resend-api-key",
                "property": "value",
            },
        }
    ]


def test_mailer_mounts_only_the_product_file_read_only_when_enabled():
    for enabled in [False, True]:
        spec = resource(documents(enabled), "Deployment", "onboarding-api")["spec"][
            "template"
        ]["spec"]
        container = spec["containers"][0]
        environment = {entry["name"]: entry.get("value") for entry in container["env"]}
        mounts = {mount["name"]: mount for mount in container.get("volumeMounts", [])}
        if enabled:
            assert environment["HELIVANTA_EMAIL_FROM"] == "onboarding@helivanta.app"
            assert (
                environment["HELIVANTA_RESEND_API_KEY_FILE"]
                == "/var/run/helivanta-email/api-key"
            )
            assert mounts["helivanta-email"]["readOnly"] is True
            assert "subPath" not in mounts["helivanta-email"]
            volume = next(v for v in spec["volumes"] if v["name"] == "helivanta-email")
            assert volume["secret"]["secretName"] == "onboarding-helivanta-resend"
            assert volume["secret"]["defaultMode"] == 288
        else:
            assert "HELIVANTA_EMAIL_FROM" not in environment
            assert "helivanta-email" not in mounts


def test_missing_sender_refuses_mail_activation():
    chart = ROOT / "charts/apps/onboarding-service"
    result = subprocess.run(
        [
            "helm",
            "template",
            "onboarding-service",
            str(chart),
            "-f",
            str(chart / "values-prod.yaml"),
            "--set",
            "helivantaEmail.enabled=true",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
