import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location(
    "storage", ROOT / "scripts/store-openpanel-client-id.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Client:
    def __init__(self, existing=None):
        self.existing = existing
        self.calls = []

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET":
            return {"data": self.existing}
        self.existing = {"data": body["data"]}


def test_store_uses_product_prefix_and_create_only_cas():
    client = Client()
    module.store("prod", "admin", "fixture", client)
    writes = [c for c in client.calls if c[0] == "POST"]
    assert writes == [
        (
            "POST",
            "kv/data/mark8ly/app/mark8ly-openpanel-admin-client-id",
            {"options": {"cas": 0}, "data": {"value": "fixture"}},
        )
    ]


def test_existing_same_value_is_idempotent_and_different_value_is_rejected():
    client = Client({"data": {"value": "fixture"}})
    module.store("prod", "admin", "fixture", client)
    assert all(c[0] == "GET" for c in client.calls)
    with pytest.raises(ValueError):
        module.store("prod", "admin", "different", client)
    assert all(c[0] == "GET" for c in client.calls)


def test_environment_separation_and_validation():
    client = Client()
    module.store("devtest", "storefront", "fixture", client)
    assert all(
        c[1].startswith("kv/data/mark8ly-development/app/mark8ly-")
        for c in client.calls
    )
    for env, app in [("prod", "../other"), ("other", "admin")]:
        with pytest.raises(ValueError):
            module.store(env, app, "fixture", client)


def test_permission_failure_never_attempts_a_write():
    class Forbidden(Client):
        def request(self, method, path, body=None):
            self.calls.append((method, path, body))
            raise module.MigrationError("HTTP 403")

    client = Forbidden()
    with pytest.raises(module.MigrationError):
        module.store("prod", "admin", "fixture", client)
    assert [c[0] for c in client.calls] == ["GET"]
