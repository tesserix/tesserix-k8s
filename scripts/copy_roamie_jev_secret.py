"""Create Roamie's JEV credential from one explicitly pinned Kora KV version."""

import argparse
import hmac
import importlib.util
import os
from pathlib import Path


class CopyError(Exception):
    pass


SOURCE = "kv/data/kora/app/kora-typesafe-api-key"
TARGET = "kv/data/roamie/app/roamie-typesafe-api-key"


def value(response):
    try:
        result = response["data"]["data"]["value"]
        version = response["data"]["metadata"]["version"]
        if not isinstance(result, str) or not result or any(c.isspace() for c in result):
            raise CopyError("Invalid key format; details withheld")
        if not isinstance(version, int) or version < 1:
            raise CopyError("Invalid source version")
        return result, version
    except (KeyError, TypeError):
        raise CopyError("Missing KV value/version; details withheld") from None


def copy(bao, source_version):
    if not isinstance(source_version, int) or isinstance(source_version, bool) or source_version < 1:
        raise CopyError("An explicit positive source version is required")
    source, actual = value(bao.request("GET", SOURCE + f"?version={source_version}"))
    if actual != source_version:
        raise CopyError("Pinned source version did not match")
    existing = bao.request("GET", TARGET)
    if existing is not None:
        current, version = value(existing)
        if not hmac.compare_digest(source.encode(), current.encode()):
            raise CopyError("Destination contains a different key; nothing was overwritten")
        return version
    bao.request("POST", TARGET, {"options": {"cas": 0}, "data": {"value": source}})
    current, version = value(bao.request("GET", TARGET))
    if not hmac.compare_digest(source.encode(), current.encode()):
        raise CopyError("Copy verification failed; details withheld")
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-version", type=int, required=True)
    parser.add_argument("--bao-addr", default="http://127.0.0.1:18200")
    args = parser.parse_args()
    token = os.environ.pop("BAO_TOKEN", "")
    if not token:
        parser.error("Set BAO_TOKEN to a short-lived token scoped to the source and destination")
    spec = importlib.util.spec_from_file_location("bao_transport", Path(__file__).with_name("migrate_fe3dr_secret.py"))
    transport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transport)
    try:
        version = copy(transport.OpenBao(args.bao_addr, token), args.source_version)
    except (CopyError, transport.MigrationError):
        raise SystemExit("JEV copy stopped; source/destination values and response details withheld") from None
    print(f"Verified Roamie JEV copy: source version {args.source_version}, destination version {version}")


if __name__ == "__main__":
    main()
