import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("roamie_jev_copy", ROOT / "scripts/copy_roamie_jev_secret.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Bao:
    def __init__(self, existing=None):
        self.existing = existing
        self.writes = []

    def request(self, method, path, body=None):
        if method == "GET" and "kora/app/" in path:
            assert path.endswith("?version=7")
            return {"data": {"data": {"value": "synthetic-key"}, "metadata": {"version": 7}}}
        if method == "POST":
            self.writes.append((path, body))
            assert body["options"] == {"cas": 0}
            self.existing = body["data"]["value"]
            return {"data": {"version": 1}}
        if self.existing is None:
            return None
        return {"data": {"data": {"value": self.existing}, "metadata": {"version": 1}}}


def test_copy_pins_source_and_creates_only_the_exact_roamie_path():
    bao = Bao()
    assert module.copy(bao, 7) == 1
    assert bao.writes[0][0] == "kv/data/roamie/app/roamie-typesafe-api-key"


def test_identical_copy_is_idempotent_and_different_value_is_never_overwritten():
    same = Bao("synthetic-key")
    assert module.copy(same, 7) == 1
    assert not same.writes
    different = Bao("different-key")
    with pytest.raises(module.CopyError, match="different"):
        module.copy(different, 7)
    assert not different.writes
