import pathlib
import subprocess
import yaml

ROOT = pathlib.Path(__file__).parents[1]


def test_production_api_and_worker_use_openbao_with_writes_enabled():
    chart = ROOT / "charts/apps/homechef-api"
    docs = yaml.safe_load_all(
        subprocess.check_output(
            [
                "helm",
                "template",
                "homechef-api",
                str(chart),
                "--namespace",
                "homechef",
                "-f",
                str(chart / "values-prod.yaml"),
            ],
            text=True,
        )
    )
    deployments = [d for d in docs if d and d["kind"] == "Deployment"]
    assert len(deployments) == 2
    for deployment in deployments:
        container = deployment["spec"]["template"]["spec"]["containers"][0]
        env = {e["name"]: e.get("value") for e in container["env"]}
        assert env["APP_SECRET_WRITES_PAUSED"] == "false"
        assert env["APP_SECRET_STORE"] == "openbao"
        assert env["PII_SECRET_STORE"] == "openbao"
        assert env["OPENBAO_ROLE"] == "runtime-fe3dr-payment"
        assert env["OPENBAO_PII_ROLE"] == "app-homechef_homechef-api"
        assert env["OPENBAO_ADDR"] == "http://openbao.openbao.svc.cluster.local:8200"
