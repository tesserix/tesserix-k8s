from pathlib import Path

import yaml


JOB_TEMPLATE = Path("charts/apps/devai-registry-bootstrap/templates/job.yaml")


def test_multistatus_with_rejected_artifact_counts_as_error() -> None:
    template = JOB_TEMPLATE.read_text(encoding="utf-8")
    multistatus = template.split("elif r.status_code == 207:", maxsplit=1)[1].split(
        "else:", maxsplit=1
    )[0]

    assert "err += 1" in multistatus
    assert "ok += 1" not in multistatus


def test_seed_source_is_pinned_to_the_adk_registry_release() -> None:
    values = yaml.safe_load(
        Path("charts/apps/devai-registry-bootstrap/values.yaml").read_text(
            encoding="utf-8"
        )
    )
    template = JOB_TEMPLATE.read_text(encoding="utf-8")

    assert values["seedSource"]["ref"] == "6df9ff5e28cca12f453d3caae5815a3908958943"
    assert values["reseedNonce"] == "2026-08-23-governed-agent-composition-v2"
    assert 'git -C /workspace/devai fetch --depth=1 origin "$REF"' in template
    assert "git -C /workspace/devai checkout --detach FETCH_HEAD" in template
