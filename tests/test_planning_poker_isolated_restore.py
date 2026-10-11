import subprocess
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_restore_replaces_source_auto_config_without_following_symlink(tmp_path):
    job = yaml.safe_load((ROOT / "manifests/planning-poker-restore-check/job.yaml").read_text())
    script = job["spec"]["template"]["spec"]["containers"][0]["args"][0]
    start = script.index("cat > /restore/postgresql.conf")
    end = script.index("rm -f /restore/data/standby.signal")
    fragment = script[start:end].replace("/restore", str(tmp_path / "restore"))
    data = tmp_path / "restore/data"
    data.mkdir(parents=True)
    original = tmp_path / "source-config"
    original.write_text("source configuration must remain unchanged")
    (data / "postgresql.auto.conf").symlink_to(original)
    subprocess.run(["bash", "-ec", fragment], check=True)
    assert original.read_text() == "source configuration must remain unchanged"
    assert not (data / "postgresql.auto.conf").is_symlink()
    assert "primary_conninfo = ''" in (data / "postgresql.auto.conf").read_text()


def test_postgres_dollar_quotes_survive_kubernetes_argument_expansion():
    import re

    job = yaml.safe_load((ROOT / "manifests/planning-poker-restore-check/job.yaml").read_text())
    script = job["spec"]["template"]["spec"]["containers"][0]["args"][0]
    sql = script.split("<<'SQL'\n", 1)[1].split("\nSQL", 1)[0]
    expanded = sql.replace("$$", "$")
    delimiters = re.findall(r"\$(?:[a-zA-Z_][a-zA-Z_0-9]*)?\$", sql)
    assert delimiters
    assert re.findall(r"\$(?:[a-zA-Z_][a-zA-Z_0-9]*)?\$", expanded) == delimiters
