from pathlib import Path


JOB_TEMPLATE = Path("charts/apps/devai-registry-bootstrap/templates/job.yaml")


def test_multistatus_with_rejected_artifact_fails_the_bootstrap() -> None:
    template = JOB_TEMPLATE.read_text(encoding="utf-8")
    multistatus = template.split("elif r.status_code == 207:", maxsplit=1)[1].split("else:", maxsplit=1)[0]

    assert "errors += 1" in multistatus
    assert "ok += 1" not in multistatus
