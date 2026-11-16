import re
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).parents[1]
CHART = ROOT / "charts/thirdparty/growthbook"


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
    inline = tmp_path / "inline.yaml"
    inline.write_text(helm.get("values", "{}"))
    objects = tmp_path / "objects.yaml"
    objects.write_text(yaml.safe_dump(helm.get("valuesObject", {})))
    result = render("-f", str(inline), "-f", str(objects))
    assert result.returncode == 0, result.stderr
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
