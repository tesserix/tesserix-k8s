import re
from pathlib import Path


SPEC = Path("tests/e2e/specs/admin/custom-domain-login.spec.ts")


def test_admin_e2e_credentials_come_from_environment() -> None:
    source = SPEC.read_text()

    assert "requiredEnv('E2E_ADMIN_EMAIL')" in source
    assert "requiredEnv('E2E_ADMIN_PASSWORD')" in source
    assert not re.search(r"const (?:EMAIL|PASSWORD)\s*=\s*['\"]", source)


def test_admin_e2e_does_not_record_session_material() -> None:
    source = SPEC.read_text()

    for forbidden in ("allHeaders()", "initialCookies", "finalCookies", "responseHeaders"):
        assert forbidden not in source


def test_generated_admin_e2e_artifacts_are_not_committed() -> None:
    screenshots = Path("tests/e2e/screenshots/custom-domain-login")

    assert not screenshots.exists()
    assert "tests/e2e/screenshots/" in Path(".gitignore").read_text().splitlines()
