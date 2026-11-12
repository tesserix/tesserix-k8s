import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
FLAG = "WORKFORCE_EMPLOYMENT_ACTIVATION_ENABLED"
APPROVED_SOURCE = "02b1e2b7e5a0fb9fa1fdbc65e449ca322cfda56a"


def render(tmp_path, values):
    config = tmp_path / "values.yaml"
    config.write_text(yaml.safe_dump(values))
    return list(
        yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "helivanta-api",
                    str(ROOT / "charts/apps/helivanta-api"),
                    "--namespace",
                    "helivanta",
                    "--values",
                    str(config),
                    "--set-string",
                    f"image.tag={APPROVED_SOURCE}",
                ],
                text=True,
            )
        )
    )


def activation_consumers(resources):
    return {
        (r["metadata"]["name"], c["name"]): e["value"]
        for r in resources
        if r and r["kind"] == "Deployment"
        for c in r["spec"]["template"]["spec"]["containers"]
        for e in c.get("env", [])
        if e["name"] == FLAG
    }


def test_default_install_leaves_activation_off(tmp_path):
    assert activation_consumers(render(tmp_path, {})) == {}


def test_approved_production_switch_only_enables_owner_on_promoted_image(tmp_path):
    app = yaml.safe_load(
        (ROOT / "argocd/prod/apps/helivanta/helivanta-api.yaml").read_text()
    )
    resources = render(tmp_path, app["spec"]["source"]["helm"]["valuesObject"])
    assert activation_consumers(resources) == {("helivanta-api", "api"): "true"}
    api = next(
        r
        for r in resources
        if r and r["kind"] == "Deployment" and r["metadata"]["name"] == "helivanta-api"
    )
    assert api["spec"]["template"]["spec"]["containers"][0]["image"].endswith(
        ":" + APPROVED_SOURCE
    )
    assert (
        api["spec"]["template"]["metadata"]["labels"]["sidecar.istio.io/inject"]
        == "true"
    )
