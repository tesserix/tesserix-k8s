import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "rocketchat_bootstrap", ROOT / "scripts/identity/bootstrap-rocketchat.py"
)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class Bao:
    def __init__(self, value=None):
        self.value = value
        self.writes = []

    def request(self, method, path, body=None):
        if method == "GET":
            return (
                None
                if self.value is None
                else {
                    "data": {"data": {"value": self.value}, "metadata": {"version": 1}}
                }
            )
        assert body["options"]["cas"] == 0
        self.writes.append(path)
        self.value = body["data"]["value"]


def test_provisioning_is_idempotent_and_never_rotates_existing_credentials():
    bao = Bao()
    bootstrap.create(bao, "mongodb-password", "synthetic-value")
    bootstrap.create(bao, "mongodb-password", "synthetic-value")
    assert bao.writes == [bootstrap.PREFIX + "mongodb-password"]
    with pytest.raises(ValueError, match="rotation is not authorized"):
        bootstrap.create(bao, "mongodb-password", "different-value")
    assert bao.value == "synthetic-value"
    with pytest.raises(ValueError, match="Unapproved"):
        bootstrap.create(bao, "../other/product", "value")


class Identity:
    def __init__(self):
        self.project = {"hasProjectCheck": True, "projectRoleCheck": True}
        self.users = [
            {
                "id": str(i),
                "human": {"email": {"email": email, "isEmailVerified": True}},
            }
            for i, email in enumerate(sorted(bootstrap.MEMBERS))
        ]
        self.grants = [
            {"userId": user["id"], "roleKeys": ["admin"]} for user in self.users
        ]

    def expect(self, method, path, body=None):
        if method == "GET":
            return {"project": self.project}
        return {"result": self.grants if "/grants/" in path else self.users}


def test_project_verification_rejects_outsiders_unverified_email_and_disabled_checks():
    identity = Identity()
    bootstrap.verify_project(identity, {"id": "test-project"})
    identity.grants.append({"userId": "outsider", "roleKeys": ["admin"]})
    with pytest.raises(ValueError, match="exactly the two"):
        bootstrap.verify_project(identity, {"id": "test-project"})
    identity = Identity()
    identity.users[0]["human"]["email"]["isEmailVerified"] = False
    with pytest.raises(ValueError, match="unique and verified"):
        bootstrap.verify_project(identity, {"id": "test-project"})
    identity = Identity()
    identity.project["projectRoleCheck"] = False
    with pytest.raises(ValueError, match="user role grants"):
        bootstrap.verify_project(identity, {"id": "test-project"})


def test_missing_rocketchat_secret_is_treated_as_unprovisioned():
    import urllib.error

    class Missing:
        def open(self, request, timeout):
            raise urllib.error.HTTPError(request.full_url, 404, "not found", {}, None)

    bao = bootstrap.OpenBao("http://127.0.0.1:18200", "synthetic-token")
    bao.opener = Missing()
    assert bootstrap.read(bao, "mongodb-password") is None


def test_role_grants_restrict_users_without_an_organization_access_check():
    identity = Identity()
    identity.project.pop("hasProjectCheck")
    bootstrap.verify_project(identity, {"id": "test-project"})
