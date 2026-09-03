from pathlib import Path
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "k8s/operators/evals-onboarding/resources.yaml"


def documents(path: Path) -> list[dict]:
    return [item for item in yaml.safe_load_all(path.read_text()) if isinstance(item, dict)]


def resource(items: list[dict], kind: str, name: str) -> dict:
    return next(item for item in items if item["kind"] == kind and item["metadata"]["name"] == name)


def test_operator_reaches_only_langfuse_web_and_global_pooler() -> None:
    policy = resource(documents(RESOURCES), "NetworkPolicy", "evals-onboarding-operator")
    assert policy["spec"]["policyTypes"] == ["Ingress", "Egress"]
    assert policy["spec"]["ingress"] == []
    namespaced = {
        (peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"], port["port"])
        for rule in policy["spec"]["egress"]
        for peer in rule.get("to", [])
        if "namespaceSelector" in peer
        for port in rule["ports"]
    }
    assert namespaced == {("kube-system", 53), ("observability", 3000), ("global", 5432)}
    hbone = next(rule for rule in policy["spec"]["egress"] if {p["port"] for p in rule["ports"]} == {15008})
    assert hbone["to"] == [{"ipBlock": {"cidr": "10.20.0.0/16"}}]


def test_operator_mounts_org_key_and_grader_password_from_gcp() -> None:
    items = documents(RESOURCES)
    org = resource(items, "ExternalSecret", "langfuse-org-credentials")
    assert {d["remoteRef"]["key"] for d in org["spec"]["data"]} == {
        "prod-langfuse-org-public-key",
        "prod-langfuse-org-secret-key",
    }
    db = resource(items, "ExternalSecret", "evals-db-credentials")
    assert db["spec"]["data"][0]["remoteRef"]["key"] == "prod-grader-postgresql-password"
    deployment = resource(items, "Deployment", "evals-onboarding-operator")
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert "--secret-prefix=prod-" in container["args"]
    assert any(arg.startswith("--evals-db-url=postgres://grader@global-postgres-pooler-rw.global") for arg in container["args"])
    assert not any("password" in arg.lower() and "@" in arg and ":" in arg.split("@")[0].split("//")[-1] for arg in container["args"])
    assert {m["mountPath"] for m in container["volumeMounts"]} == {"/var/run/langfuse-org", "/var/run/evals-db"}
    account = resource(items, "ServiceAccount", "evals-onboarding-operator")
    assert account["metadata"]["annotations"]["iam.gke.io/gcp-service-account"].startswith("evals-onboarding-operator@")


def test_global_postgres_admits_evals_operator() -> None:
    rendered = subprocess.run(
        ["helm", "template", "istio-config", str(ROOT / "charts/thirdparty/istio-config"), "--namespace", "istio-system"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    items = [d for d in yaml.safe_load_all(rendered) if d]
    policy = resource(items, "NetworkPolicy", "allow-global-ingress")
    namespaces = {
        peer["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
        for rule in policy["spec"]["ingress"]
        for peer in rule.get("from", [])
        if "namespaceSelector" in peer
    }
    assert "evals-operator" in namespaces


def test_every_claim_registers_at_least_one_dataset() -> None:
    claims_dir = ROOT / "k8s/operators/evals-onboarding/claims"
    listed = yaml.safe_load((claims_dir / "kustomization.yaml").read_text())["resources"]
    for name in listed:
        claim = yaml.safe_load((claims_dir / name).read_text())
        assert claim["kind"] == "EvalOnboarding"
        assert claim["metadata"]["namespace"] == "evals-operator"
        assert claim["metadata"]["name"] == Path(name).stem
        assert claim["spec"]["datasets"], name
        assert {d["modality"] for d in claim["spec"]["datasets"]} <= {"agent", "retrieval", "ocr", "transcription"}
