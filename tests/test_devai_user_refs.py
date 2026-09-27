import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1] / "scripts"))
from migrate_devai_user_refs import destination, replacement

ROW = {
    "scope": "user",
    "scope_id": "synthetic-user",
    "connector_key": "llm",
    "instance_id": "default",
}
OLD = "devai-user-synthetic-user-llm-default-openai_api_key"


def test_preserves_other_references_and_owner():
    row = ROW | {
        "secret_refs": {"openai_api_key": OLD, "other": "devai/devai-api/existing/keep"}
    }
    path = destination(row, "openai_api_key", "123456789abc")
    assert path.startswith("devai/devai-api/")
    assert path.split("/")[-1].startswith("devai-user-synthetic-user-")
    assert path.endswith("-migration-123456789abc")
    updated = replacement(row, {"openai_api_key": path})
    assert updated["other"] == row["secret_refs"]["other"]
    assert row["secret_refs"]["openai_api_key"] == OLD
    assert (
        destination(
            ROW | {"scope_id": "another-user"}, "openai_api_key", "123456789abc"
        ).split("/")[2]
        != path.split("/")[2]
    )


@pytest.mark.parametrize(
    "change",
    [
        {"scope": "global"},
        {"connector_key": "github"},
        {"instance_id": "other"},
        {"scope_id": ""},
    ],
)
def test_rejects_unreviewed_scope(change):
    with pytest.raises(ValueError):
        destination(ROW | change, "openai_api_key", "123456789abc")


def test_rejects_replacing_an_existing_openbao_reference():
    with pytest.raises(ValueError):
        replacement(
            ROW | {"secret_refs": {"openai_api_key": "devai/devai-api/existing/keep"}},
            {"openai_api_key": "new"},
        )


def test_rejects_wrong_owner_and_unknown_field():
    with pytest.raises(ValueError):
        destination(ROW, "arbitrary", "123456789abc")
    with pytest.raises(ValueError):
        replacement(
            ROW | {"secret_refs": {"openai_api_key": OLD}},
            {"openai_api_key": "devai/devai-api/incorrect/devai-key"},
        )
