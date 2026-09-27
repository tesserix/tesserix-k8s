from pathlib import Path

ROOT = Path(__file__).parents[1] / "terraform-new/stacks"


def test_roamie_database_handoff_preserves_remote_credentials():
    text = (ROOT / "07-app-secrets/roamie-database.tf").read_text()
    assert "resource " not in text
    for suffix in ("roamie_database", "roamie_database_runtime"):
        for kind in (
            "random_password",
            "google_secret_manager_secret",
            "google_secret_manager_secret_version",
        ):
            assert f"from = {kind}.{suffix}" in text
    assert text.count("destroy = false") == 6


def test_document_database_handoff_excludes_openbao_products():
    text = (ROOT / "15-document-intelligence-products/main.tf").read_text()
    assert 'try(r.secretBackend, "openbao") == "gcp"' in text
    assert text.count("for_each = local.gcp_secret_releases") == 3
    for kind in (
        "random_password",
        "google_secret_manager_secret",
        "google_secret_manager_secret_version",
    ):
        assert f"from = {kind}.database" in text
        assert f'resource "{kind}" "database_gcp"' in text
    assert text.count("destroy = false") == 3
