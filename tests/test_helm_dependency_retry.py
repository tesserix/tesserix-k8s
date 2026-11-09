"""The external Helm CLI boundary can fail transiently without hiding bad charts."""
from pathlib import Path
import os
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "build-chart-dependency.sh"


def run_helm(tmp_path: Path, failures: int, error: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
    tools = tmp_path / "bin"
    tools.mkdir()
    calls = tmp_path / "calls"
    stub = tools / "helm"
    stub.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$HELM_TEST_CALLS"
count=$(wc -l < "$HELM_TEST_CALLS")
if [ "$count" -le "$HELM_TEST_FAILURES" ]; then
  printf '%s\\n' "$HELM_TEST_ERROR" >&2
  exit 7
fi
printf 'TEST dependency build succeeded\\n'
''')
    stub.chmod(0o755)
    (tools / "sleep").write_text("#!/bin/sh\nexit 0\n")
    (tools / "sleep").chmod(0o755)
    result = subprocess.run(
        ["bash", str(SCRIPT), "charts/TEST chart/"],
        env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
             "HELM_TEST_CALLS": str(calls), "HELM_TEST_FAILURES": str(failures),
             "HELM_TEST_ERROR": error},
        text=True, capture_output=True, timeout=20, check=False,
    )
    return result, calls.read_text().splitlines() if calls.exists() else []


@pytest.mark.parametrize("error", ["504 Gateway Timeout", "429 Too Many Requests", "TLS handshake timeout"])
def test_recovers_transient_helm_download_without_changing_the_request(tmp_path: Path, error: str) -> None:
    result, calls = run_helm(tmp_path, 2, error)
    assert result.returncode == 0, result.stdout + result.stderr
    assert calls == ["dependency build charts/TEST chart/"] * 3
    assert "TEST dependency build succeeded" in result.stdout


def test_exhausted_retry_preserves_failure_and_error(tmp_path: Path) -> None:
    result, calls = run_helm(tmp_path, 9, "504 Gateway Timeout")
    assert result.returncode == 7
    assert len(calls) == 3
    assert "504 Gateway Timeout" in result.stdout + result.stderr


@pytest.mark.parametrize("error", ["can't get a valid version", "404 Not Found", "manifest unknown"])
def test_permanent_chart_or_artifact_errors_fail_immediately(tmp_path: Path, error: str) -> None:
    result, calls = run_helm(tmp_path, 9, error)
    assert result.returncode == 7
    assert len(calls) == 1
    assert error in result.stdout + result.stderr


def test_success_never_retries(tmp_path: Path) -> None:
    result, calls = run_helm(tmp_path, 0, "")
    assert result.returncode == 0
    assert len(calls) == 1
