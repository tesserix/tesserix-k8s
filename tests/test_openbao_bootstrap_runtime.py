"""Bootstrap uses the tested SDK interpreter and versions its immutable Job."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINT = ROOT / "charts/thirdparty/openbao/files/bootstrap_entrypoint.sh"


def sdk_environment(tmp_path, reported_python=None):
    binary = tmp_path / "bin"
    sdk = tmp_path / "sdk"
    binary.mkdir()
    sdk.mkdir()
    python = sdk / "python3"
    python.symlink_to(sys.executable)
    for tool in ("curl", "bash"):
        target = binary / tool
        target.write_text("#!/bin/sh\nexit 0\n")
        target.chmod(0o755)
    gcloud = binary / "gcloud"
    gcloud.write_text("#!/bin/sh\nprintf '%s\\n' " + shlex.quote(reported_python or str(python)) + "\n")
    gcloud.chmod(0o755)
    return {**os.environ, "PATH": str(binary)}, python


def test_launcher_uses_the_sdk_python_when_the_initial_path_has_none(tmp_path):
    environment, python = sdk_environment(tmp_path)
    probe = tmp_path / "probe.py"
    probe.write_text("import json,shutil,sys; print(json.dumps({'python':sys.executable,'alias':shutil.which('python3'),'args':sys.argv[1:]}))")
    result = subprocess.check_output(["/bin/sh", str(ENTRYPOINT), str(probe), "run", "file with spaces"], env=environment, text=True)
    result = json.loads(result)
    assert Path(result["python"]).resolve() == python.resolve()
    assert result["alias"] == str(python)
    assert result["args"] == ["run", "file with spaces"]


@pytest.mark.parametrize("location", ["python3", "/missing/sdk/python3"])
def test_launcher_refuses_an_unavailable_runtime_before_executing_payload(tmp_path, location):
    environment, _ = sdk_environment(tmp_path, location)
    result = subprocess.run(["/bin/sh", str(ENTRYPOINT), "not-executed.py"], env=environment, text=True, capture_output=True)
    assert result.returncode != 0
    assert "OpenBao bootstrap" in result.stderr
    assert "not-executed.py" not in result.stderr


def rendered(tag=None):
    command = ["helm", "template", "runtime-test", "charts/thirdparty/openbao"]
    if tag:
        command += ["--set-string", "bootstrap.image.tag=" + tag]
    return list(yaml.safe_load_all(subprocess.check_output(command, cwd=ROOT, text=True)))


def test_job_uses_the_launcher_and_runtime_changes_produce_a_new_job():
    current = rendered()
    changed = rendered("changed-runtime")
    job = next(item for item in current if item and item["kind"] == "Job" and item["metadata"]["name"].startswith("openbao-bootstrap-"))
    next_job = next(item for item in changed if item and item["kind"] == "Job" and item["metadata"]["name"].startswith("openbao-bootstrap-"))
    container = job["spec"]["template"]["spec"]["containers"][0]
    assert container["command"] == ["/bin/sh", "/config/bootstrap_entrypoint.sh", "/config/recovery_record.py", "run", "/config/bootstrap.sh"]
    assert container["image"].endswith("@sha256:08c9cb2c82625689f26172f46f2cefdf30c3449959a71492569a824b537d369f")
    assert job["metadata"]["name"] != next_job["metadata"]["name"]
    config = next(item for item in current if item and item["kind"] == "ConfigMap" and item["metadata"]["name"] == "openbao-bootstrap")
    assert config["data"]["bootstrap_entrypoint.sh"] == ENTRYPOINT.read_text()
