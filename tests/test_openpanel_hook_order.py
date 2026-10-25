import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/thirdparty/openpanel"


def test_database_bootstrap_runs_after_migrations_and_before_workloads():
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "openpanel",
            str(CHART),
            "--namespace",
            "openpanel",
            "--values",
            str(CHART / "values-prod.yaml"),
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    jobs = {
        document["metadata"]["name"]: document
        for document in yaml.safe_load_all(rendered)
        if document and document.get("kind") == "Job"
    }

    migrate = jobs["openpanel-migrate"]
    bootstrap = jobs["openpanel-project-init"]

    assert migrate["metadata"]["annotations"]["argocd.argoproj.io/hook"] == "PreSync"
    assert migrate["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "-2"
    assert bootstrap["metadata"]["annotations"]["argocd.argoproj.io/hook"] == "PreSync"
    assert bootstrap["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "-1"
    assert (
        "HookSucceeded"
        in bootstrap["metadata"]["annotations"]["argocd.argoproj.io/hook-delete-policy"]
    )


def test_project_init_is_hardened_and_keeps_tokens_out_of_argv():
    rendered = subprocess.run(
        [
            "helm",
            "template",
            "openpanel",
            str(CHART),
            "--namespace",
            "openpanel",
            "--values",
            str(CHART / "values-prod.yaml"),
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    documents = [document for document in yaml.safe_load_all(rendered) if document]
    bootstrap = next(
        document
        for document in documents
        if document.get("kind") == "Job"
        and document["metadata"]["name"] == "openpanel-project-init"
    )
    pod_spec = bootstrap["spec"]["template"]["spec"]
    container = pod_spec["containers"][0]
    command = "\n".join(container["command"])

    assert container["image"].startswith(
        "asia-south1-docker.pkg.dev/tesseracthub-480811/ghcr-remote/"
        "tesserix/openpanel-project-init:main-"
    )
    assert "apk add" not in command
    assert "curl " not in command
    assert "Authorization: Bearer" not in command
    assert "kubectl apply -f -" in command
    assert pod_spec["automountServiceAccountToken"] is False
    token_volume = next(
        volume for volume in pod_spec["volumes"] if volume["name"] == "kube-api-access"
    )
    token_source = next(
        source["serviceAccountToken"]
        for source in token_volume["projected"]["sources"]
        if "serviceAccountToken" in source
    )
    assert token_source["expirationSeconds"] == 600
    assert pod_spec["securityContext"]["runAsNonRoot"] is True
    assert container["securityContext"] == {
        "allowPrivilegeEscalation": False,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": True,
    }

    assert not any(
        document.get("kind") in {"ClusterRole", "ClusterRoleBinding"}
        and document["metadata"]["name"] == "openpanel-project-init"
        for document in documents
    )
    roles = {
        document["metadata"]["namespace"]: document
        for document in documents
        if document.get("kind") == "Role"
        and document["metadata"]["name"] == "openpanel-project-init"
    }
    assert set(roles) == {"homechef", "mark8ly", "tesserix"}
    for role in roles.values():
        assert role["rules"] == [
            {
                "apiGroups": [""],
                "resources": ["secrets"],
                "verbs": ["get", "create", "update", "patch"],
            }
        ]


def test_project_client_id_export_uses_supported_local_kubectl(tmp_path):
    import base64
    import os
    import shutil

    rendered = subprocess.check_output(
        [
            "helm",
            "template",
            "openpanel",
            str(CHART),
            "-n",
            "openpanel",
            "-f",
            str(CHART / "values-prod.yaml"),
        ],
        text=True,
    )
    job = next(
        d
        for d in yaml.safe_load_all(rendered)
        if d
        and d["kind"] == "Job"
        and d["metadata"]["name"] == "openpanel-project-init"
    )
    script = job["spec"]["template"]["spec"]["containers"][0]["command"][-1]
    start = script.index("write_secret() {")
    function = script[start : script.index("\n}", start) + 2]
    real = shutil.which("kubectl")
    assert real
    wrapper = tmp_path / "kubectl"
    wrapper.write_text(
        '#!/bin/bash\nset -eu\nif [ "$1" = apply ]; then cat > "$RESULT"; test -s "$RESULT"; exit; fi\ncase "$1" in\ncreate) [[ " $* " == *" --dry-run=client "* ]] ;;\nlabel) [[ " $* " == *" --local "* ]] ;;\n*) exit 90 ;;\nesac\nexec '
        + real
        + ' "$@"\n'
    )
    wrapper.chmod(0o755)
    config = tmp_path / "kubeconfig"
    config.write_text(
        "apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n"
    )
    result = tmp_path / "result.yaml"
    env = dict(
        os.environ,
        PATH=str(tmp_path) + os.pathsep + os.environ["PATH"],
        KUBECONFIG=str(config),
        TMPDIR=str(tmp_path),
        SECRET_NAME="openpanel-client-ids",
        RESULT=str(result),
    )
    run = subprocess.run(
        [
            "bash",
            "-c",
            "set -euo pipefail\n"
            + function
            + "\nwrite_secret consumer storefront-client-id example-public-id",
        ],
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    assert run.returncode == 0, run.stderr
    secret = yaml.safe_load(result.read_text())
    assert secret["metadata"]["name"] == "openpanel-client-ids"
    assert secret["metadata"]["namespace"] == "consumer"
    assert secret["metadata"]["labels"] == {
        "app.kubernetes.io/managed-by": "openpanel-init",
        "app.kubernetes.io/part-of": "tesseract-hub",
    }
    assert secret["data"] == {
        "storefront-client-id": base64.b64encode(b"example-public-id").decode()
    }
