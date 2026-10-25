import pytest
import yaml
from test_homechef_park import ROOT, render


@pytest.mark.parametrize("phase", ["quiesce", "copy", "reconcile"])
@pytest.mark.parametrize(
    "chart",
    [
        "charts/apps/mark8ly-mongodb",
        "charts/apps/support-platform-mongo",
        "charts/thirdparty/growthbook",
    ],
)
def test_mongo_migration_stops_writers_and_retains_claims(chart, phase):
    def database(docs):
        return next(
            d
            for d in docs
            if d["kind"] == "StatefulSet"
            or (
                d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-mongodb")
            )
        )

    normal = database(render(chart))
    paused = database(render(chart, overrides=(f"storageMigrationPhase={phase}",)))
    assert normal["spec"]["replicas"] == 1
    assert paused["spec"]["replicas"] == 0
    if paused["kind"] == "StatefulSet":
        assert paused["spec"]["persistentVolumeClaimRetentionPolicy"] == {
            "whenDeleted": "Retain",
            "whenScaled": "Retain",
        }
        assert (
            paused["spec"]["volumeClaimTemplates"]
            == normal["spec"]["volumeClaimTemplates"]
        )


@pytest.mark.parametrize(
    "file",
    [
        "argocd/prod/apps/mark8ly/mongodb.yaml",
        "argocd/prod/apps/ai-apps/support-platform-mongo.yaml",
        "argocd/prod/infrastructure/growthbook.yaml",
    ],
)
def test_mongo_owner_automation_is_paused_in_git_during_claim_replacement(file):
    app = yaml.safe_load((ROOT / file).read_text())
    phase = (
        app["spec"]["source"]["helm"]
        .get("valuesObject", {})
        .get("storageMigrationPhase")
    )
    enabled = app["spec"]["syncPolicy"]["automated"].get("enabled")
    if phase:
        assert enabled is False
    else:
        assert enabled is not False


@pytest.mark.parametrize(
    "chart", ["charts/apps/mark8ly-mongodb", "charts/apps/support-platform-mongo"]
)
@pytest.mark.parametrize("phase", ["", "quiesce", "copy", "reconcile"])
def test_mongo_force_replacement_only_during_stopped_reconcile(chart, phase):
    sts = next(
        d
        for d in render(chart, overrides=(f"storageMigrationPhase={phase}",))
        if d["kind"] == "StatefulSet"
    )
    flags = (
        sts["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-options")
    )
    if phase == "reconcile":
        assert flags == "Force=true,Replace=true"
        assert sts["spec"]["replicas"] == 0
        assert (
            sts["spec"]["persistentVolumeClaimRetentionPolicy"]["whenDeleted"]
            == "Retain"
        )
    else:
        assert flags is None


def test_growthbook_preserves_inline_configuration_during_migration():
    app = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/growthbook.yaml").read_text()
    )
    helm = app["spec"]["source"]["helm"]
    assert "valuesObject" not in helm
    values = yaml.safe_load(helm["values"])
    assert values["resources"]["limits"]["memory"] == "2Gi"
    assert values["mongodb"]["persistence"]["storageClassName"] == "economy-rwo-retain"
    assert values["persistence"]["storageClassName"] == "economy-rwo"
    assert "Replace=true" not in app["spec"]["syncPolicy"]["syncOptions"]


def test_growthbook_retains_explicit_existing_pvc_bindings():
    docs = render(
        "charts/thirdparty/growthbook",
        overrides=(
            "persistence.volumeName=uploads-existing",
            "mongodb.persistence.volumeName=mongo-verified",
        ),
    )
    claims = {
        d["metadata"]["name"]: d for d in docs if d["kind"] == "PersistentVolumeClaim"
    }
    assert (
        claims["park-test-growthbook-uploads"]["spec"]["volumeName"]
        == "uploads-existing"
    )
    assert (
        claims["park-test-growthbook-mongodb"]["spec"]["volumeName"] == "mongo-verified"
    )


@pytest.mark.parametrize("product", ["helivanta", "dwellm8"])
@pytest.mark.parametrize("phase", ["", "quiesce", "reconcile"])
def test_product_nats_migration_stops_and_retains_without_affecting_normal_mode(
    product, phase
):
    docs = render(
        "charts/apps/nats",
        f"values-{product}.yaml",
        overrides=(f"storageMigrationPhase={phase}",),
    )
    sts = next(d for d in docs if d["kind"] == "StatefulSet")
    assert sts["spec"]["replicas"] == (0 if phase else 1)
    assert sts["spec"]["persistentVolumeClaimRetentionPolicy"] == {
        "whenDeleted": "Retain",
        "whenScaled": "Retain",
    }
    assert sts["metadata"].get("annotations", {}).get(
        "argocd.argoproj.io/sync-options"
    ) == ("Force=true,Replace=true" if phase == "reconcile" else None)


@pytest.mark.parametrize("phase", ["", "quiesce", "copy"])
def test_openpanel_migration_stops_database_writers_and_clients(phase):
    docs = render(
        "charts/thirdparty/openpanel",
        "values-prod.yaml",
        overrides=(f"storageMigrationPhase={phase}",),
    )
    workloads = {
        d["metadata"]["name"].rsplit("-", 1)[-1]: d
        for d in docs
        if d["kind"] == "Deployment"
    }
    for component in [
        "api",
        "worker",
        "dashboard",
        "postgresql",
        "clickhouse",
        "redis",
    ]:
        assert workloads[component]["spec"]["replicas"] == (0 if phase else 1)


def test_openpanel_static_claims_preserve_verified_postgres_and_redis_bindings():
    docs = render(
        "charts/thirdparty/openpanel",
        "values-prod.yaml",
        overrides=(
            "postgresql.persistence.volumeName=postgres-verified",
            "redis.persistence.volumeName=redis-verified",
        ),
    )
    claims = {
        d["metadata"]["name"].rsplit("-", 1)[-1]: d
        for d in docs
        if d["kind"] == "PersistentVolumeClaim"
    }
    assert claims["postgresql"]["spec"]["volumeName"] == "postgres-verified"
    assert claims["redis"]["spec"]["volumeName"] == "redis-verified"
