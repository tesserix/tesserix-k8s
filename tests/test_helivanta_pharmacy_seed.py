import types
import urllib.error

import pytest
import yaml

from test_helivanta_pharmacy_evidence import ROOT, render, resource


def initializer():
    module = types.ModuleType("pharmacy_seed")
    script = ROOT / "charts/apps/helivanta-postgres/files/pharmacy-evidence-seed.py"
    exec(compile(script.read_text(), str(script), "exec"), module.__dict__)
    return module


def metadata(deleted=False, destroyed=False):
    return {"data": {"current_version": 1, "versions": {"1": {"deletion_time": "deleted" if deleted else "", "destroyed": destroyed}}}}


def test_initializer_creates_once_without_reading_or_overwriting_passwords():
    seed = initializer()
    calls = []

    class Client:
        exists = False

        def call(self, path, data=None):
            calls.append((path, data))
            if path == seed.METADATA:
                if not self.exists:
                    raise urllib.error.HTTPError(path, 404, "absent", {}, None)
                return metadata()
            assert path == seed.DATA and data is not None, "secret data is never read"
            assert not self.exists, "existing credential must never be overwritten"
            assert data["options"] == {"cas": 0}
            assert set(data["data"]) == {"password"}
            assert len(data["data"]["password"]) == 64
            self.exists = True
            return {}

    client = Client()
    seed.initialize(client)
    seed.initialize(client)
    assert sum(path == seed.DATA for path, _ in calls) == 1


@pytest.mark.parametrize("deleted,destroyed", [(True, False), (False, True)])
def test_deleted_history_requires_recovery_without_another_write(deleted, destroyed):
    seed = initializer()

    class Client:
        def call(self, path, data=None):
            assert path == seed.METADATA and data is None
            return metadata(deleted, destroyed)

    with pytest.raises(RuntimeError, match="approved recovery"):
        seed.initialize(Client())


def test_initializer_refuses_excess_or_missing_authority():
    seed = initializer()

    class Client:
        data_permissions = ["create"]

        def call(self, path, data):
            assert path == "sys/capabilities-self"
            assert data == {"paths": [seed.DATA, seed.METADATA]}
            return {"data": {seed.DATA: self.data_permissions, seed.METADATA: ["read"]}}

    client = Client()
    seed.assert_scoped(client)
    for permissions in [["root"], ["create", "read"], ["create", "update"], ["deny"]]:
        client.data_permissions = permissions
        with pytest.raises(RuntimeError, match="authority"):
            seed.assert_scoped(client)


def test_seed_has_only_projected_short_token_and_narrow_network():
    items = render("charts/apps/helivanta-postgres", "pharmacyEvidenceWorker.seed.enabled=true")
    jobs = [r for r in items if r["kind"] == "Job" and r["metadata"]["name"].startswith("helivanta-pharmacy-evidence-secret-seed-")]
    assert len(jobs) == 1
    job = jobs[0]
    assert job["spec"]["activeDeadlineSeconds"] == 300
    pod = job["spec"]["template"]["spec"]
    assert pod["serviceAccountName"] == "helivanta-pharmacy-evidence-secret-seed"
    assert not pod["automountServiceAccountToken"]
    assert not pod["containers"][0].get("envFrom")
    assert not pod["containers"][0].get("env")
    projected = next(v for v in pod["volumes"] if v["name"] == "token")["projected"]
    assert projected["sources"] == [{"serviceAccountToken": {"path": "token", "expirationSeconds": 600}}]
    policy = resource(items, "NetworkPolicy", "helivanta-pharmacy-evidence-secret-seed")
    ports = {p["port"] for r in policy["spec"]["egress"] for p in r["ports"]}
    assert ports == {53, 8200, 15008, 15012}
    cluster = resource(items, "Cluster", "helivanta-postgres")
    role = next(r for r in cluster["spec"]["managed"]["roles"] if r["name"] == "helivanta_pharmacy_evidence_worker")
    assert not role.get("login"), "initialization does not activate database access"


def test_seed_policy_is_exact_create_only_with_short_single_identity():
    values = yaml.safe_load((ROOT / "charts/thirdparty/openbao/values.yaml").read_text())["bootstrap"]
    name = "seed-helivanta-pharmacy-evidence-worker-production"
    policy = next(p["hcl"] for p in values["policies"] if p["name"] == name)
    assert 'path "kv/data/helivanta/production/helivanta-pharmacy-evidence-worker-db-password" { capabilities = ["create"] }' in policy
    assert 'path "kv/metadata/helivanta/production/helivanta-pharmacy-evidence-worker-db-password" { capabilities = ["read"] }' in policy
    assert "*" not in policy and "delete" not in policy and "list" not in policy
    role = next(r for r in values["kubernetesRoles"] if r["name"] == name)
    assert role["serviceAccounts"] == ["helivanta-pharmacy-evidence-secret-seed"]
    assert role["namespaces"] == ["helivanta"]
    assert role["policies"] == [name] and role["ttl"] == "5m"
