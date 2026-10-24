import json
import os
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "charts/thirdparty/mongodb-backup/files"


def test_blog_backup_separates_dump_from_upload():
    app = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/mongodb-blog-backup.yaml").read_text()
    )
    documents = list(
        yaml.safe_load_all(
            subprocess.check_output(
                [
                    "helm",
                    "template",
                    "backup",
                    str(ROOT / "charts/thirdparty/mongodb-backup"),
                    "--values",
                    "-",
                ],
                input=app["spec"]["source"]["helm"]["values"],
                text=True,
            )
        )
    )
    pod = next(d for d in documents if d and d["kind"] == "CronJob")["spec"][
        "jobTemplate"
    ]["spec"]["template"]["spec"]
    assert pod["initContainers"][0]["name"] == "dump"
    assert "library/mongo@sha256:" in pod["initContainers"][0]["image"]
    assert pod["containers"][0]["name"] == "upload"
    assert all(e["name"] != "MONGO_PASSWORD" for e in pod["containers"][0]["env"])
    assert pod["containers"][0]["volumeMounts"][0]["readOnly"] is True


@pytest.mark.parametrize("fail", [False, True])
def test_dump_preserves_credential_arguments_and_fails_closed(tmp_path, fail):
    binary = tmp_path / "bin"
    binary.mkdir()
    (binary / "mongosh").write_text('#!/bin/bash\nprintf "tesserix_blog\\n"\n')
    (binary / "mongodump").write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['ARG_CAPTURE']).write_text(json.dumps(sys.argv[1:]))
if os.environ['FAIL_DUMP'] == 'true': sys.exit(7)
archive = next(a.split('=', 1)[1] for a in sys.argv if a.startswith('--archive='))
Path(archive).write_bytes(b'verified fixture')
""")
    for item in binary.iterdir():
        item.chmod(0o755)
    destination = tmp_path / "backup"
    env = dict(
        os.environ,
        PATH=str(binary) + os.pathsep + os.environ["PATH"],
        BACKUP_DIR=str(destination),
        AUTH_ENABLED="true",
        MONGO_USER="admin",
        MONGO_PASSWORD="dummy:p@ss with space",
        MONGO_AUTH_DB="admin",
        MONGO_HOST="db",
        MONGO_PORT="27017",
        ARG_CAPTURE=str(tmp_path / "args.json"),
        FAIL_DUMP=str(fail).lower(),
    )
    result = subprocess.run(
        ["bash", str(FILES / "dump.sh")],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert "--password=dummy:p@ss with space" in json.loads(
        (tmp_path / "args.json").read_text()
    )
    assert (destination / "dump-complete").exists() is not fail
    assert (result.returncode == 0) is not fail


def test_upload_failure_is_not_reported_as_success(tmp_path):
    binary = tmp_path / "bin"
    binary.mkdir()
    command = binary / "gsutil"
    command.write_text("#!/bin/bash\nexit 9\n")
    command.chmod(0o755)
    (tmp_path / "dump-complete").write_text("1\n")
    (tmp_path / "db.archive.gz").write_bytes(b"fixture")
    env = dict(
        os.environ,
        PATH=str(binary) + os.pathsep + os.environ["PATH"],
        BACKUP_DIR=str(tmp_path),
        GCS_BUCKET="test",
        GCS_PREFIX="backup",
    )
    result = subprocess.run(
        ["bash", str(FILES / "upload.sh")],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert "upload completed" not in result.stdout


def test_upload_uses_explicit_directory_without_bucket_listing(tmp_path):
    binary = tmp_path / "bin"
    binary.mkdir()
    command = binary / "gsutil"
    command.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$ARG_CAPTURE"\n')
    command.chmod(0o755)
    (tmp_path / "dump-complete").write_text("1\n")
    (tmp_path / "db.archive.gz").write_bytes(b"fixture")
    capture = tmp_path / "args"
    subprocess.run(
        ["bash", str(FILES / "upload.sh")],
        env=dict(
            os.environ,
            PATH=str(binary) + os.pathsep + os.environ["PATH"],
            BACKUP_DIR=str(tmp_path),
            GCS_BUCKET="test",
            GCS_PREFIX="prod/blog",
            ARG_CAPTURE=str(capture),
        ),
        check=True,
    )
    assert capture.read_text().splitlines()[-1] == "gs://test/prod/blog/"
