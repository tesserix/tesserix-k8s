#!/bin/sh
set -eu
source_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target=${1:?usage: checkout.sh EMPTY_BUILD_DIRECTORY}
mkdir -p "$target"
for component in ax substrate; do
  url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["url"])' "$source_root/sources.json" "$component")
  revision=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["commit"])' "$source_root/sources.json" "$component")
  git clone --no-checkout "$url" "$target/$component"
  git -C "$target/$component" checkout --detach "$revision"
  git -C "$target/$component" apply --check "$source_root/$component.patch"
  git -C "$target/$component" apply "$source_root/$component.patch"
done
