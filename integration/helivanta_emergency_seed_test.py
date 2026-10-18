import importlib.util
import subprocess
import time
import urllib.error
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "seed", ROOT / "charts/apps/helivanta-postgres/files/emergency-seed.py"
)
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


def test_real_openbao_create_only_acl_concurrency_and_deleted_version_refusal():
    container = subprocess.check_output(
        [
            "docker",
            "run",
            "--rm",
            "-d",
            "-p",
            "127.0.0.1::8200",
            "-e",
            "BAO_DEV_ROOT_TOKEN_ID=synthetic-local-root",
            "openbao/openbao:2.6.2",
            "server",
            "-dev",
            "-dev-listen-address=0.0.0.0:8200",
        ],
        text=True,
    ).strip()
    try:
        port = (
            subprocess.check_output(["docker", "port", container, "8200"], text=True)
            .strip()
            .split(":")[-1]
        )
        base = f"http://127.0.0.1:{port}/v1/"
        admin = seed.Client(base, "synthetic-local-root")
        deadline = time.monotonic() + 30
        while True:
            try:
                admin.call("sys/health")
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)
        admin.call("sys/mounts/kv", {"type": "kv", "options": {"version": "2"}})
        values = yaml.safe_load(
            (ROOT / "charts/thirdparty/openbao/values.yaml").read_text()
        )
        policy = next(
            p["hcl"]
            for p in values["bootstrap"]["policies"]
            if p["name"] == "seed-helivanta-emergency-worker-production"
        )
        admin.call("sys/policies/acl/seed", {"policy": policy}, method="PUT")
        token = admin.call(
            "auth/token/create",
            {"policies": ["seed"], "no_default_policy": True, "ttl": "5m"},
        )["auth"]["client_token"]
        client = seed.Client(base, token)
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: seed.initialize(client), range(8)))
        original = admin.call(seed.DATA)["data"]
        assert len(original["data"]["password"]) >= 48
        assert original["metadata"]["version"] == 1
        seed.initialize(client)
        assert admin.call(seed.DATA)["data"] == original
        for method, path, data in [
            ("GET", seed.DATA, None),
            (
                "POST",
                seed.DATA,
                {"options": {"cas": 1}, "data": {"password": "changed"}},
            ),
            ("POST", seed.DATA + "-other", {"data": {"password": "other"}}),
            ("DELETE", seed.DATA, None),
        ]:
            with pytest.raises(urllib.error.HTTPError) as error:
                client.call(path, data, method=method)
            assert error.value.code == 403
        admin.call(seed.DATA, method="DELETE")
        with pytest.raises(RuntimeError, match="recovery"):
            seed.initialize(client)
        assert admin.call(seed.METADATA)["data"]["current_version"] == 1
    finally:
        subprocess.run(["docker", "stop", container], check=True, capture_output=True)
