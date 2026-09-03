from pathlib import Path
import subprocess

import yaml


JOB_TEMPLATE = Path("charts/apps/devai-registry-bootstrap/templates/job.yaml")


def test_multistatus_with_rejected_artifact_counts_as_error() -> None:
    template = JOB_TEMPLATE.read_text(encoding="utf-8")
    multistatus = template.split("elif status == 207:", maxsplit=1)[1].split(
        "else:", maxsplit=1
    )[0]

    assert "err += 1" in multistatus
    assert "ok += 1" not in multistatus


def test_bootstrap_fails_unless_every_seed_is_applied() -> None:
    template = JOB_TEMPLATE.read_text(encoding="utf-8")

    assert "sys.exit(0 if ok > 0 and err == 0 else 1)" in template


def test_seed_source_is_pinned_to_the_adk_registry_release() -> None:
    values = yaml.safe_load(
        Path("charts/apps/devai-registry-bootstrap/values.yaml").read_text(
            encoding="utf-8"
        )
    )
    template = JOB_TEMPLATE.read_text(encoding="utf-8")

    assert values["seedSource"]["ref"] == "1239d51482c66b1789931ec7022e7020aed80f00"
    assert values["reseedNonce"] == "2026-09-03-stateless-product-mcp-v1"
    assert 'git -C /workspace/devai fetch --depth=1 origin "$REF"' in template
    assert "git -C /workspace/devai checkout --detach FETCH_HEAD" in template


def test_bootstrap_uses_standard_library_http_without_runtime_install() -> None:
    template = JOB_TEMPLATE.read_text(encoding="utf-8")

    assert "pip install" not in template
    assert "import requests" not in template
    assert "urllib.request" in template
    assert "urllib.error.HTTPError" in template


def test_upsert_container_is_hardened_with_a_writable_tmp_volume() -> None:
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "devai-registry-bootstrap",
            "charts/apps/devai-registry-bootstrap",
            "--namespace",
            "devai",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    job = next(
        document
        for document in yaml.safe_load_all(rendered)
        if document and document.get("kind") == "Job"
    )
    pod_spec = job["spec"]["template"]["spec"]
    upsert = next(
        container for container in pod_spec["containers"] if container["name"] == "upsert"
    )

    assert pod_spec["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
    assert upsert["securityContext"] == {
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": True,
        "runAsGroup": 65532,
        "runAsNonRoot": True,
        "runAsUser": 65532,
    }
    assert {"name": "tmp", "mountPath": "/tmp"} in upsert["volumeMounts"]
    assert {"name": "tmp", "emptyDir": {}} in pod_spec["volumes"]
