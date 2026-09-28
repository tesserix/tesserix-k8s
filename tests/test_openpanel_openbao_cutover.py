import os
import subprocess
import yaml

from test_homechef_openbao_access import ROOT, resource


def test_all_openpanel_credential_readers_use_openbao():
    docs = list(
        yaml.safe_load_all(
            (ROOT / "external-secrets/prod/openpanel/externalsecret.yaml").read_text()
        )
    )
    docs += list(
        yaml.safe_load_all(
            (ROOT / "k8s/operators/analytics-onboarding/resources.yaml").read_text()
        )
    )
    docs += list(
        yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "openpanel",
                    str(ROOT / "charts/thirdparty/openpanel"),
                    "--namespace",
                    "openpanel",
                    "-f",
                    str(ROOT / "charts/thirdparty/openpanel/values-prod.yaml"),
                ],
                text=True,
            )
        )
    )
    for name in (
        "openpanel-secrets",
        "openpanel-root-credentials",
        "openpanel-oauth2-secrets",
    ):
        secret = resource(docs, "ExternalSecret", name)
        assert secret["spec"]["secretStoreRef"] == {
            "kind": "SecretStore",
            "name": "openbao-openpanel-production",
        }
        for binding in secret["spec"]["data"]:
            ref = binding["remoteRef"]
            assert ref["property"] == "value"
            if binding["secretKey"] == "marketplace-internal-auth":
                assert ref["key"] == "mark8ly/app/mark8ly-audit-ingest-secret"
                assert binding["sourceRef"]["storeRef"] == {
                    "name": "openbao-mark8ly-production",
                    "kind": "SecretStore",
                }
            else:
                assert ref["key"].startswith("openpanel/app/openpanel-")


def test_analytics_operator_declares_openbao_without_gcp_identity():
    docs = list(
        yaml.safe_load_all(
            (ROOT / "k8s/operators/analytics-onboarding/resources.yaml").read_text()
        )
    )
    sa = resource(docs, "ServiceAccount", "analytics-onboarding-operator")
    assert "iam.gke.io/gcp-service-account" not in sa["metadata"].get("annotations", {})
    deployment = resource(docs, "Deployment", "analytics-onboarding-operator")
    args = deployment["spec"]["template"]["spec"]["containers"][0]["args"]
    assert "--openbao-products=devai,langfuse" in args
    assert "--openbao-role=analytics-onboarding-writer" in args
    assert not any(
        arg.startswith(("--gcp-", "--secret-prefix", "--secret-manager"))
        for arg in args
    )
    policy = resource(docs, "NetworkPolicy", "analytics-onboarding-operator")
    assert all(
        peer.get("ipBlock", {}).get("cidr")
        not in ("169.254.169.254/32", "169.254.169.252/32")
        for rule in policy["spec"]["egress"]
        for peer in rule.get("to", [])
    )


def test_manual_setup_never_falls_back_to_gcp(tmp_path):
    script = (ROOT / "scripts/setup-openpanel-projects.sh").read_text()
    function = script.split("get_root_credentials() {", 1)[1].split("\n}\n", 1)[0]
    marker = tmp_path / "gcp-called"
    command = """
log_info() { :; }
log_ok() { :; }
log_error() { :; }
gcloud() { touch "$GCP_MARKER"; printf 'legacy-value'; }
unset OPENPANEL_PROD_ROOT_CLIENT_ID OPENPANEL_PROD_ROOT_CLIENT_SECRET
get_root_credentials() { FUNCTION
}
get_root_credentials prod
""".replace("FUNCTION", function)
    result = subprocess.run(
        ["bash", "-c", command],
        env={**os.environ, "GCP_MARKER": str(marker)},
        capture_output=True,
        text=True,
    )
    assert result.returncode == 1
    assert not marker.exists()
    supplied = subprocess.run(
        [
            "bash",
            "-c",
            command.replace(
                "unset OPENPANEL_PROD_ROOT_CLIENT_ID OPENPANEL_PROD_ROOT_CLIENT_SECRET",
                "OPENPANEL_PROD_ROOT_CLIENT_ID=test-id\nOPENPANEL_PROD_ROOT_CLIENT_SECRET=test-secret",
            )
            + '\n[[ "$ROOT_CLIENT_ID" == test-id && "$ROOT_CLIENT_SECRET" == test-secret ]]',
        ],
        capture_output=True,
        text=True,
    )
    assert supplied.returncode == 0


def test_analytics_operator_keeps_scoped_kubernetes_api_egress():
    docs = list(
        yaml.safe_load_all(
            (ROOT / "k8s/operators/analytics-onboarding/resources.yaml").read_text()
        )
    )
    policy = resource(docs, "NetworkPolicy", "analytics-onboarding-operator")
    destinations = {
        peer["ipBlock"]["cidr"]
        for rule in policy["spec"]["egress"]
        if {"protocol": "TCP", "port": 443} in rule.get("ports", [])
        for peer in rule.get("to", [])
        if "ipBlock" in peer
    }
    assert destinations == {"10.30.0.1/32", "172.16.0.0/28"}
