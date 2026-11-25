"""Verify the exact reviewed acceptance window, never a wildcard rollout."""
from pathlib import Path
import yaml

ROOT=Path(__file__).resolve().parents[1]

def test_only_the_named_yes_hospital_tenant_has_a_fixed_pilot_window():
    app=yaml.safe_load((ROOT/"argocd/prod/apps/helivanta/helivanta-api.yaml").read_text())
    assert app["spec"]["source"]["targetRevision"] == "51683003f997ff5e98f39b2eda0232202ebd402c"
    values=app["spec"]["source"]["helm"]["valuesObject"]
    assert values["releaseCapabilities"]["pilot"] == {
        "enabled": True,
        "tenantIDs": ["351d2d39-7a35-5d85-ab5d-bcd22bb0a18b"],
        "expiresAt": "2026-11-26T06:00:00Z",
    }
    for other in ["helivanta-global-api", "helivanta-shell"]:
        raw=(ROOT/f"argocd/prod/apps/helivanta/{other}.yaml").read_text()
        assert "RELEASE_PILOT_POLICY_FILE" not in raw


def test_growthbook_catalogue_consumer_uses_the_reviewed_compatible_chart():
    app=yaml.safe_load((ROOT/"argocd/prod/apps/helivanta/helivanta-growthbook.yaml").read_text())
    assert app["spec"]["source"]["targetRevision"] == "51683003f997ff5e98f39b2eda0232202ebd402c"
