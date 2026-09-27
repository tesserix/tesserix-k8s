#!/usr/bin/env python3
"""Run recovery alert scenarios against the rendered chart (requires promtool)."""

from pathlib import Path
import shutil
import subprocess
import tempfile

import yaml

root = Path(__file__).resolve().parents[1]
rendered = subprocess.check_output(
    [
        "helm",
        "template",
        "openbao",
        str(root / "charts/thirdparty/openbao"),
        "--namespace",
        "openbao",
    ],
    text=True,
)
rules = next(
    doc["spec"]
    for doc in yaml.safe_load_all(rendered)
    if doc and doc["kind"] == "PrometheusRule"
)
with tempfile.TemporaryDirectory(prefix="openbao-alert-tests-") as directory:
    target = Path(directory)
    (target / "openbao-recovery-rules.yaml").write_text(yaml.safe_dump(rules))
    shutil.copy(root / "tests/prometheus/openbao-recovery.test.yaml", target)
    subprocess.run(
        ["promtool", "test", "rules", "openbao-recovery.test.yaml"],
        cwd=target,
        check=True,
    )
