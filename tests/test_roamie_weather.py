from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).parents[1]
DIGEST = "sha256:" + "a" * 64


def render(enabled=True):
    args = ["helm", "template", "roamie-ai", str(ROOT / "charts/apps/roamie-ai"), "-f", str(ROOT / "charts/apps/roamie-ai/values-validation.yaml"),
            "--namespace", "roamie", "--set", "weather.enabled=" + str(enabled).lower(),
            "--set-string", "weather.digest=" + DIGEST]
    return [d for d in yaml.safe_load_all(subprocess.check_output(args, text=True)) if d]


def test_weather_is_private_nonroot_bounded_and_has_real_readiness():
    docs = render()
    service = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"] == "roamie-weather")
    assert service["spec"].get("type", "ClusterIP") == "ClusterIP"
    assert not any(d["kind"] in ("Ingress", "HTTPRoute") for d in docs)
    deploy = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "roamie-weather")
    pod = deploy["spec"]["template"]["spec"]
    assert deploy["spec"]["replicas"] == 2
    assert pod["automountServiceAccountToken"] is False
    assert pod["securityContext"]["runAsNonRoot"] is True
    container = pod["containers"][0]
    assert container["image"].endswith("@" + DIGEST)
    config = {v["name"]: v["value"] for v in container["env"]}
    assert config["REMOTE_DATA_DIRECTORY"] == "https://openmeteo.s3.amazonaws.com/data/"
    assert config["CACHE_SIZE"] == "8GB"
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    assert container["securityContext"]["allowPrivilegeEscalation"] is False
    assert container["resources"]["limits"]["memory"] == "10Gi"
    assert container["readinessProbe"]["exec"]["command"] == ["python3", "/app/check_forecast.py"]
    assert not any(v.get("persistentVolumeClaim") for v in pod["volumes"])
    assert next(v for v in pod["volumes"] if v["name"] == "weather-cache")["emptyDir"]["sizeLimit"] == "20Gi"
    auth = next(d for d in docs if d["kind"] == "AuthorizationPolicy" and d["metadata"]["name"] == "roamie-weather")
    assert auth["spec"]["rules"][0]["from"][0]["source"]["principals"] == ["cluster.local/ns/roamie/sa/roamie-trip-manager"]
    manager = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "roamie-trip-manager")
    env = {e["name"]: e.get("value") for e in manager["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["ROAMIE_MANAGER_OPEN_METEO_SELF_HOSTED"] == "true"
    secrets = next(d for d in docs if d["kind"] == "ExternalSecret" and d["metadata"]["name"] == "roamie-trip-manager")
    assert any(e["secretKey"] == "ROAMIE_MANAGER_WEATHER_API_KEY" for e in secrets["spec"]["data"])


def test_weather_is_not_rolled_out_with_an_unpublished_image():
    args = ["helm", "template", "roamie-ai", str(ROOT / "charts/apps/roamie-ai"), "-f", str(ROOT / "charts/apps/roamie-ai/values-validation.yaml"), "--set", "weather.enabled=true", "--set-string", "weather.digest="]
    result = subprocess.run(args, text=True, capture_output=True)
    assert result.returncode != 0
    assert "immutable" in result.stderr


def test_disabled_weather_does_not_change_the_manager_provider():
    docs = render(False)
    assert not any(d["metadata"]["name"] == "roamie-weather" for d in docs)
    manager = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "roamie-trip-manager")
    assert not any(e["name"] == "ROAMIE_MANAGER_OPEN_METEO_SELF_HOSTED" for e in manager["spec"]["template"]["spec"]["containers"][0]["env"])
