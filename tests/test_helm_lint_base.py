import os
import shutil
import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_chart_testing_uses_event_base_after_main_advances(tmp_path):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=tmp_path, text=True).strip()

    git("init", "-q")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.invalid")
    chart = tmp_path / "charts/apps/example/Chart.yaml"
    chart.parent.mkdir(parents=True)
    chart.write_text("version: 0.1.0\n")
    git("add", ".")
    git("commit", "-qm", "base")
    base = git("rev-parse", "HEAD")
    chart.write_text("version: 0.1.1\n")
    git("commit", "-qam", "release")
    git("update-ref", "refs/remotes/origin/main", "HEAD")
    (tmp_path / "scripts").mkdir()
    shutil.copy(ROOT / "scripts/chart_version_policy.py", tmp_path / "scripts")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    ct = fake_bin / "ct"
    ct.write_text("""#!/usr/bin/env python3
import subprocess, sys
branch = next((arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--target-branch=')), 'main')
old = subprocess.check_output(['git', 'show', f'origin/{branch}:charts/apps/example/Chart.yaml'], text=True)
assert old == 'version: 0.1.0\\n', old
if sys.argv[1] == 'list-changed':
    print('charts/apps/example')
else:
    assert '--check-version-increment=true' in sys.argv
""")
    ct.chmod(0o755)
    workflow = yaml.safe_load((ROOT / ".github/workflows/helm-lint.yaml").read_text())
    output = tmp_path / "output"
    for name in ("List changed charts", "Run chart-testing lint"):
        step = next(
            s for s in workflow["jobs"]["lint"]["steps"] if s.get("name") == name
        )
        result = subprocess.run(
            [shutil.which("bash"), "-e", "-c", step["run"]],
            cwd=tmp_path,
            env={
                **os.environ,
                "BASE_SHA": base,
                "GITHUB_OUTPUT": str(output),
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
            },
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, result.stderr
        assert output.read_text() == "changed=true\n"
