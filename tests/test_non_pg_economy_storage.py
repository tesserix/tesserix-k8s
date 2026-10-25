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
