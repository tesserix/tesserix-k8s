import re
import subprocess
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
TFVARS = (ROOT / "terraform-new/environments/prod/terraform.tfvars").read_text()
STORAGE = (ROOT / "terraform-new/stacks/03-storage/main.tf").read_text()
FOUNDATION = (ROOT / "terraform-new/stacks/01-foundation/main.tf").read_text()
PLATFORM = ROOT / "k8s/platform/document-intelligence"


KORA_BUCKETS = {
    "kora-prod-doc-quarantine-in",
    "kora-prod-doc-accepted-in",
    "kora-prod-doc-derived-in",
    "kora-prod-doc-results-in",
}

SHARED_BUCKETS = {
    "doc-int-prod-sandbox-in",
    "doc-int-prod-candidates-in",
    "doc-int-prod-train-cal-in",
    "doc-int-prod-dev-eval-in",
    "doc-int-prod-eval-results-in",
    "doc-int-prod-model-staging-in",
    "doc-int-prod-golden-in",
}


def object_body(name: str) -> str:
    match = re.search(rf'name\s*=\s*"{re.escape(name)}"', TFVARS)
    assert match is not None, name
    start = match.start()
    opening = TFVARS.rfind("{", 0, start)
    depth = 0
    for index in range(opening, len(TFVARS)):
        if TFVARS[index] == "{":
            depth += 1
        elif TFVARS[index] == "}":
            depth -= 1
            if depth == 0:
                return TFVARS[opening : index + 1]
    raise AssertionError(f"unterminated object for {name}")


def grants(service_account: str) -> set[tuple[str, str]]:
    body = object_body(service_account)
    return set(
        re.findall(
            r'bucket\s*=\s*"([^"]+)"[^}]*role\s*=\s*"([^"]+)"',
            body,
            re.DOTALL,
        )
    )


def test_document_buckets_are_regional_private_versioned_and_cmek_encrypted() -> None:
    for name in KORA_BUCKETS | SHARED_BUCKETS:
        body = object_body(name)
        assert 'location                    = "asia-south1"' in body
        assert "force_destroy               = false" in body
        assert "uniform_bucket_level_access = true" in body
        assert 'public_access_prevention    = "enforced"' in body
        assert "versioning                  = true" in body
        assert re.search(r'kms_key_name\s*=\s*"[^\"]+"', body)
        assert re.search(r"cors\s*=\s*\[\]", body)
        assert re.search(r"iam_bindings\s*=\s*\[\]", body)


def test_kora_runtime_identities_cannot_access_shared_corpora() -> None:
    expected = {
        "kora-doc-signer": {
            ("kora-prod-doc-quarantine-in", "roles/storage.objectCreator"),
            ("kora-prod-doc-quarantine-in", "roles/storage.objectViewer"),
        },
        "kora-doc-scanner": {
            ("kora-prod-doc-quarantine-in", "roles/storage.objectAdmin"),
            ("kora-prod-doc-accepted-in", "roles/storage.objectCreator"),
        },
        "kora-doc-worker": {
            ("kora-prod-doc-accepted-in", "roles/storage.objectViewer"),
            ("kora-prod-doc-derived-in", "roles/storage.objectAdmin"),
            ("kora-prod-doc-results-in", "roles/storage.objectCreator"),
        },
        "kora-doc-result-api": {
            ("kora-prod-doc-results-in", "roles/storage.objectViewer")
        },
        "kora-doc-lifecycle": {
            (bucket, "roles/storage.objectAdmin") for bucket in KORA_BUCKETS
        },
    }
    for identity, allowed in expected.items():
        actual = grants(identity)
        assert actual == allowed
        assert not ({bucket for bucket, _ in actual} & SHARED_BUCKETS)
        assert "roles/storage.admin" not in {role for _, role in actual}


def test_kora_sandbox_runtime_isolated_from_production_and_expires_in_one_day() -> None:
    sandbox = {
        "kora-dev-doc-quarantine-in",
        "kora-dev-doc-accepted-in",
        "kora-dev-doc-derived-in",
        "kora-dev-doc-results-in",
    }
    for name in sandbox:
        body = object_body(name)
        assert 'environment = "sandbox"' in body
        assert 'condition = { age = 1 }' in body
        assert "kora-prod-doc-" not in body
    expected = {
        "kora-dev-doc-signer": {("kora-dev-doc-quarantine-in", "roles/storage.objectCreator"), ("kora-dev-doc-quarantine-in", "roles/storage.objectViewer")},
        "kora-dev-doc-scanner": {("kora-dev-doc-quarantine-in", "roles/storage.objectAdmin"), ("kora-dev-doc-accepted-in", "roles/storage.objectCreator")},
        "kora-dev-doc-worker": {("kora-dev-doc-accepted-in", "roles/storage.objectViewer"), ("kora-dev-doc-derived-in", "roles/storage.objectAdmin"), ("kora-dev-doc-results-in", "roles/storage.objectCreator")},
        "kora-dev-doc-result-api": {("kora-dev-doc-results-in", "roles/storage.objectViewer")},
    }
    for identity, allowed in expected.items():
        assert grants(identity) == allowed


def test_shared_identities_cannot_access_kora_runtime_or_cross_golden_boundary() -> None:
    expected = {
        "doc-int-sandbox": {
            ("doc-int-prod-sandbox-in", "roles/storage.objectAdmin")
        },
        "doc-int-curator": {
            ("doc-int-prod-sandbox-in", "roles/storage.objectViewer"),
            ("doc-int-prod-train-cal-in", "roles/storage.objectCreator"),
            ("doc-int-prod-dev-eval-in", "roles/storage.objectCreator"),
        },
        "doc-int-trainer": {
            ("doc-int-prod-train-cal-in", "roles/storage.objectViewer"),
            ("doc-int-prod-candidates-in", "roles/storage.objectCreator"),
        },
        "doc-int-nightly-eval": {
            ("doc-int-prod-dev-eval-in", "roles/storage.objectViewer"),
            ("doc-int-prod-candidates-in", "roles/storage.objectViewer"),
            ("doc-int-prod-eval-results-in", "roles/storage.objectCreator"),
        },
        "doc-int-protected-eval": {
            ("doc-int-prod-golden-in", "roles/storage.objectViewer"),
            ("doc-int-prod-candidates-in", "roles/storage.objectViewer"),
            ("doc-int-prod-eval-results-in", "roles/storage.objectCreator"),
        },
        "doc-int-promoter": {
            ("doc-int-prod-candidates-in", "roles/storage.objectViewer"),
            ("doc-int-prod-model-staging-in", "roles/storage.objectCreator"),
        },
        "doc-int-lifecycle": {
            ("doc-int-prod-sandbox-in", "roles/storage.objectAdmin"),
            ("doc-int-prod-candidates-in", "roles/storage.objectAdmin"),
            ("doc-int-prod-eval-results-in", "roles/storage.objectAdmin"),
        },
    }
    for identity, allowed in expected.items():
        actual = grants(identity)
        assert actual == allowed
        assert not ({bucket for bucket, _ in actual} & KORA_BUCKETS)
        assert "roles/storage.admin" not in {role for _, role in actual}
    assert grants("doc-int-trainer").isdisjoint(
        {
            ("doc-int-prod-dev-eval-in", "roles/storage.objectViewer"),
            ("doc-int-prod-golden-in", "roles/storage.objectViewer"),
        }
    )


def test_every_identity_is_bound_to_one_dedicated_service_account() -> None:
    identities = {
        "kora-dev-doc-signer",
        "kora-dev-doc-scanner",
        "kora-dev-doc-worker",
        "kora-dev-doc-result-api",
        "kora-doc-signer",
        "kora-doc-scanner",
        "kora-doc-worker",
        "kora-doc-result-api",
        "kora-doc-lifecycle",
        "doc-int-sandbox",
        "doc-int-curator",
        "doc-int-trainer",
        "doc-int-nightly-eval",
        "doc-int-protected-eval",
        "doc-int-promoter",
        "doc-int-lifecycle",
    }
    for identity in identities:
        body = object_body(identity)
        assert "project_roles              = []" in body
        assert re.search(
            rf'namespace\s*=\s*"document-intelligence"\s*,?\s*'
            rf'kubernetes_service_account\s*=\s*"{identity}"',
            body,
        )


def test_cloud_storage_service_agent_can_use_each_bucket_cmek() -> None:
    assert 'data "google_storage_project_service_account" "gcs"' in STORAGE
    assert 'resource "google_kms_crypto_key_iam_member" "bucket_service_agent"' in STORAGE
    assert 'role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"' in STORAGE
    assert "data.google_storage_project_service_account.gcs.email_address" in STORAGE
    bucket_resource = STORAGE[
        STORAGE.index('resource "google_storage_bucket" "buckets"') :
        STORAGE.index("# Bucket IAM bindings")
    ]
    assert "google_kms_crypto_key_iam_member.bucket_service_agent" in bucket_resource
    key_grant = STORAGE[
        STORAGE.index(
            'resource "google_kms_crypto_key_iam_member" "bucket_service_agent"'
        ) :
        STORAGE.index("# Bucket IAM bindings")
    ]
    assert "depends_on = [google_kms_crypto_key.keys]" in key_grant


def test_managed_ocr_processor_is_generic_and_worker_scoped() -> None:
    assert '"documentai.googleapis.com"' in FOUNDATION
    assert 'resource "google_document_ai_processor" "generic_ocr"' in FOUNDATION
    assert 'type         = "OCR_PROCESSOR"' in FOUNDATION
    assert 'role    = "roles/documentai.apiUser"' in FOUNDATION
    assert 'kora-doc-worker@${var.project_id}.iam.gserviceaccount.com' in FOUNDATION


def test_platform_service_accounts_are_dedicated_and_keyless() -> None:
    rendered = subprocess.run(
        ["kubectl", "kustomize", str(PLATFORM)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    resources = [item for item in yaml.safe_load_all(rendered) if item]
    accounts = [item for item in resources if item["kind"] == "ServiceAccount"]
    expected = {
        "kora-dev-doc-signer",
        "kora-dev-doc-scanner",
        "kora-dev-doc-worker",
        "kora-dev-doc-result-api",
        "kora-doc-signer",
        "kora-doc-scanner",
        "kora-doc-worker",
        "kora-doc-result-api",
        "kora-doc-lifecycle",
        "doc-int-sandbox",
        "doc-int-curator",
        "doc-int-trainer",
        "doc-int-nightly-eval",
        "doc-int-protected-eval",
        "doc-int-promoter",
        "doc-int-lifecycle",
    }
    assert {account["metadata"]["name"] for account in accounts} == expected
    for account in accounts:
        assert account["metadata"]["namespace"] == "document-intelligence"
        assert account["automountServiceAccountToken"] is True
        annotation = account["metadata"]["annotations"][
            "iam.gke.io/gcp-service-account"
        ]
        assert annotation == (
            f'{account["metadata"]["name"]}@tesseracthub-480811.iam.gserviceaccount.com'
        )


def test_platform_is_default_deny_with_no_public_service_or_ingress() -> None:
    rendered = subprocess.run(
        ["kubectl", "kustomize", str(PLATFORM)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    resources = [item for item in yaml.safe_load_all(rendered) if item]
    assert not any(item["kind"] in {"Ingress", "Gateway", "HTTPRoute"} for item in resources)
    assert not any(
        item["kind"] == "Service" and item["spec"].get("type") in {"LoadBalancer", "NodePort"}
        for item in resources
    )
    policy = next(
        item
        for item in resources
        if item["kind"] == "NetworkPolicy" and item["metadata"]["name"] == "default-deny"
    )
    assert policy["spec"] == {
        "podSelector": {},
        "policyTypes": ["Ingress", "Egress"],
        "ingress": [],
        "egress": [],
    }


def test_global_mesh_authorizes_document_intelligence_database_access() -> None:
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "istio-config",
            str(ROOT / "charts/thirdparty/istio-config"),
            "--namespace",
            "istio-system",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    resources = [item for item in yaml.safe_load_all(rendered) if item]
    policy = next(
        item
        for item in resources
        if item["kind"] == "AuthorizationPolicy"
        and item["metadata"]["name"] == "allow-apps-to-global"
    )
    namespaces = {
        namespace
        for rule in policy["spec"]["rules"]
        for source in rule.get("from", [])
        for namespace in source.get("source", {}).get("namespaces", [])
    }

    assert "document-intelligence" in namespaces


def test_platform_argocd_application_is_registered_without_direct_apply() -> None:
    app_path = ROOT / "argocd/prod/infrastructure/document-intelligence-platform.yaml"
    app = yaml.safe_load(app_path.read_text())
    assert app["spec"]["source"]["path"] == "k8s/platform/document-intelligence"
    assert app["spec"]["destination"]["namespace"] == "document-intelligence"
    assert "CreateNamespace=true" in app["spec"]["syncPolicy"]["syncOptions"]
    assert app["spec"]["syncPolicy"]["automated"] == {"prune": True, "selfHeal": True}
    registration = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/kustomization.yaml").read_text()
    )
    assert "document-intelligence-platform.yaml" in registration["resources"]
