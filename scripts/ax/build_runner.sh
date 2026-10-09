#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
source_dir=${1:?usage: build_runner.sh AX_SOURCE_DIR IMAGE_TAG}
image_tag=${2:?usage: build_runner.sh AX_SOURCE_DIR IMAGE_TAG}
for tool in go uv crane python3; do command -v "$tool" >/dev/null; done
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/root/usr/local/bin" "$stage/root/workspace"
(cd "$source_dir" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "$stage/root/usr/local/bin/ax-task-runner" ./cmd/ax-task-runner)
cp "$source_dir/cmd/ax-task-runner/antigravity_bootstrap.py" "$stage/root/usr/local/bin/"
uv pip install --python-version 3.12 --python-platform x86_64-manylinux_2_28 \
  --only-binary :all: --require-hashes --no-compile-bytecode \
  --target "$stage/root/usr/local/lib/python3.12/site-packages" \
  -r "$root/runner-requirements.txt"
python3 - "$stage" <<'PY'
import pathlib, sys, tarfile
stage = pathlib.Path(sys.argv[1])
with tarfile.open(stage / 'runner.tar', 'w') as archive:
    for path in sorted((stage / 'root').rglob('*')):
        info = archive.gettarinfo(str(path), arcname=str(path.relative_to(stage / 'root')))
        info.uid = info.gid = info.mtime = 0
        info.uname = info.gname = ''
        if info.isfile():
            with path.open('rb') as source:
                archive.addfile(info, source)
        else:
            archive.addfile(info)
PY
base=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["python"])' "$root/images.json")
crane append --platform linux/amd64 --base "$base" --new_layer "$stage/runner.tar" --new_tag "$image_tag"
crane digest "$image_tag"
