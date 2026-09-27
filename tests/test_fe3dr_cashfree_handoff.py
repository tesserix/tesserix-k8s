import pathlib
import subprocess

import yaml

ROOT = pathlib.Path(__file__).parents[1]


def render(openbao):
    raw = subprocess.check_output(
        [
            "helm",
            "template",
            "dwellm8-api",
            str(ROOT / "charts/apps/dwellm8-api"),
            "--namespace",
            "dwellm8",
            "--set",
            "payments.cashfree.openbao=" + str(openbao).lower(),
        ],
        text=True,
    )
    secret = next(
        d for d in yaml.safe_load_all(raw) if d and d["kind"] == "ExternalSecret"
    )
    return {e["secretKey"]: e for e in secret["spec"]["data"]}


def test_cashfree_reader_stays_with_gcp_writer_until_handoff():
    data = render(False)
    for field, source in [
        ("CASHFREE_CLIENT_ID", "prod-homechef-cashfree-test-app-id"),
        ("CASHFREE_CLIENT_SECRET", "prod-homechef-cashfree-test-secret-key"),
        ("CASHFREE_WEBHOOK_SECRET", "prod-homechef-cashfree-test-secret-key"),
    ]:
        assert data[field]["remoteRef"]["key"] == source
        assert "sourceRef" not in data[field]
    assert (
        data["RESEND_API_KEY"]["sourceRef"]["storeRef"]["name"]
        == "openbao-fe3dr-appdeps"
    )


def test_cashfree_reader_can_move_with_openbao_writer_after_drain():
    data = render(True)
    for field in [
        "CASHFREE_CLIENT_ID",
        "CASHFREE_CLIENT_SECRET",
        "CASHFREE_WEBHOOK_SECRET",
    ]:
        assert data[field]["sourceRef"]["storeRef"] == {
            "kind": "SecretStore",
            "name": "openbao-fe3dr-appdeps",
        }
        assert data[field]["remoteRef"]["key"].startswith(
            "homechef/homechef-api/fe3dr-cashfree-test-"
        )
        assert data[field]["remoteRef"]["property"] == "value"
