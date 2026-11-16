import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).parents[1]
CHART = ROOT / "charts/thirdparty/growthbook"


def test_only_the_growthbook_promotion_lane_can_update_its_production_application() -> (
    None
):
    app = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/growthbook.yaml").read_text()
    )
    assert app["metadata"]["annotations"].get("kargo.akuity.io/authorized-stage") == (
        "kargo-infra:growthbook-prod"
    )


def render(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "helm",
            "template",
            "growthbook",
            str(CHART),
            "--namespace",
            "growthbook",
            *arguments,
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def image_from(rendered: str) -> str:
    deployment = next(
        item
        for item in yaml.safe_load_all(rendered)
        if item
        and item.get("kind") == "Deployment"
        and item["metadata"]["name"] == "growthbook"
    )
    return deployment["spec"]["template"]["spec"]["containers"][0]["image"]


def test_default_chart_renders_a_version_and_immutable_digest() -> None:
    result = render()
    assert result.returncode == 0, result.stderr
    assert re.fullmatch(
        r"growthbook/growthbook:5\.2\.\d+@sha256:[0-9a-f]{64}",
        image_from(result.stdout),
    )


@pytest.mark.parametrize("environment", ["prod", "pilot", "devtest"])
def test_effective_argo_values_preserve_the_release_pin(
    environment: str, tmp_path: Path
) -> None:
    app = yaml.safe_load(
        (ROOT / f"argocd/{environment}/infrastructure/growthbook.yaml").read_text()
    )
    helm = app["spec"]["source"]["helm"]
    values = tmp_path / "effective-values.yaml"
    effective = (
        yaml.safe_dump(helm["valuesObject"])
        if helm.get("valuesObject") is not None
        else helm.get("values", "{}")
    )
    values.write_text(effective)
    parameters = [
        argument
        for parameter in helm.get("parameters", [])
        for argument in (
            "--set-string" if parameter.get("forceString") else "--set",
            f"{parameter['name']}={parameter['value']}",
        )
    ]
    result = render("-f", str(values), *parameters)
    assert result.returncode == 0, result.stderr
    if environment == "prod":
        documents = list(yaml.safe_load_all(result.stdout))
        app_deployment = next(
            item
            for item in documents
            if item
            and item.get("kind") == "Deployment"
            and item["metadata"]["name"] == "growthbook"
        )
        assert (
            app_deployment["spec"]["template"]["spec"]["containers"][0]["resources"][
                "limits"
            ]["memory"]
            == "2Gi"
        )
        claims = {
            item["metadata"]["name"]: item["spec"]
            for item in documents
            if item and item.get("kind") == "PersistentVolumeClaim"
        }
        assert claims["growthbook-mongodb"]["storageClassName"] == "economy-rwo-retain"
        assert claims["growthbook-uploads"]["storageClassName"] == "economy-rwo"
        configured = yaml.safe_load(helm["values"])
        assert (
            claims["growthbook-mongodb"]["volumeName"]
            == configured["mongodb"]["persistence"]["volumeName"]
        )
        assert (
            claims["growthbook-uploads"]["volumeName"]
            == configured["persistence"]["volumeName"]
        )
    assert re.fullmatch(
        r"growthbook/growthbook:5\.2\.\d+@sha256:[0-9a-f]{64}",
        image_from(result.stdout),
    )


@pytest.mark.parametrize("tag", ["latest", "5", "5.2", "5.2.0-beta.1"])
def test_floating_or_prerelease_tags_are_refused(tag: str) -> None:
    result = render("--set-string", f"image.tag={tag}")
    assert result.returncode != 0
    assert "stable three-part version" in result.stderr


@pytest.mark.parametrize("digest", ["", "sha256:abc", "sha512:" + "a" * 64])
def test_missing_or_invalid_digest_is_refused(digest: str) -> None:
    result = render("--set-string", f"image.digest={digest}")
    assert result.returncode != 0
    assert "sha256 digest" in result.stderr
