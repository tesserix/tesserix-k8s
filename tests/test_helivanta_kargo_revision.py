from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
REPO = "https://github.com/tesserix/tesserix-k8s.git"
STAGE = "kargo-helivanta:prod"


def applications():
    for path in sorted((ROOT / "argocd/prod/apps/helivanta").glob("helivanta-*.yaml")):
        yield yaml.safe_load(path.read_text())


def promoted():
    return {
        app["metadata"]["name"]
        for app in applications()
        if app["metadata"].get("annotations", {}).get("kargo.akuity.io/authorized-stage")
        == STAGE
    }


def revision_ignores(parent):
    return [
        rule
        for rule in parent["spec"]["ignoreDifferences"]
        if "/spec/source/targetRevision" in rule["jsonPointers"]
    ]


def test_kargo_promotes_the_three_workload_applications():
    assert promoted() == {"helivanta-api", "helivanta-global-api", "helivanta-shell"}


def test_promoted_applications_have_the_single_source_the_stage_pins():
    for app in applications():
        if app["metadata"]["name"] in promoted():
            source = app["spec"]["source"]
            assert source["repoURL"] == REPO
            assert source["path"] == f"charts/apps/{app['metadata']['name']}"
            assert "sources" not in app["spec"]


def test_parent_keeps_the_revision_kargo_pinned_only_on_promoted_applications():
    parent = yaml.safe_load(
        (ROOT / "argocd/prod/apps/helivanta-app-of-apps.yaml").read_text()
    )
    assert "RespectIgnoreDifferences=true" in parent["spec"]["syncPolicy"]["syncOptions"]
    rules = revision_ignores(parent)
    assert all(
        (r["group"], r["kind"], r.get("namespace")) == ("argoproj.io", "Application", "argocd")
        for r in rules
    )
    assert sorted(r.get("name") for r in rules) == sorted(promoted())
