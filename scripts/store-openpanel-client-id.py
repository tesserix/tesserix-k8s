#!/usr/bin/env python3
"""Create an OpenPanel application identifier in OpenBao without overwriting it."""

import argparse
import os
import re
import sys
from typing import Any

from migrate_fe3dr_secret import MigrationError, OpenBao


def destination(environment: str, app: str) -> str:
    if environment not in {"prod", "devtest"} or app not in {
        "admin",
        "storefront",
        "tenant-onboarding",
    }:
        raise ValueError("Unreviewed environment/application")
    namespace = "mark8ly" if environment == "prod" else "mark8ly-development"
    return f"kv/data/{namespace}/app/mark8ly-openpanel-{app}-client-id"


def store(environment: str, app: str, value: str, client: Any) -> None:
    path = destination(environment, app)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,256}", value):
        raise ValueError("Invalid client identifier")
    try:
        existing = client.request("GET", path)
    except MigrationError as error:
        if "HTTP 404" not in str(error):
            raise
        existing = None
    data = existing.get("data") if existing else None
    if data:
        if data["data"] != {"value": value}:
            raise ValueError(
                "Existing identifier differs; review replacement separately"
            )
        return
    client.request("POST", path, {"options": {"cas": 0}, "data": {"value": value}})
    if client.request("GET", path)["data"]["data"] != {"value": value}:
        raise ValueError("Readback differs")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=["prod", "devtest"], required=True)
    parser.add_argument(
        "--app", choices=["admin", "storefront", "tenant-onboarding"], required=True
    )
    args = parser.parse_args()
    try:
        token = os.environ.pop("BAO_TOKEN", "")
        if not token:
            raise ValueError("A temporary scoped token is required")
        client = OpenBao(os.environ.get("BAO_ADDR", "http://127.0.0.1:18200"), token)
        identity = client.request("GET", "auth/token/lookup-self")["data"]
        if not 0 < identity.get("ttl", 0) <= 900 or "root" in identity.get(
            "policies", []
        ):
            raise ValueError("Use a short-lived non-root writer")
        path = destination(args.environment, args.app)
        caps = client.request("POST", "sys/capabilities-self", {"paths": [path]})
        capabilities = set(caps.get(path, caps.get("capabilities", [])))
        if capabilities != {"create", "read"}:
            raise ValueError("Require create/read-only access to the exact destination")
        store(args.environment, args.app, sys.stdin.read(), client)
        print("OpenBao identifier verified; payload withheld")
        return 0
    except (MigrationError, ValueError, KeyError, TypeError, OSError):
        print(
            "OpenBao storage failed; verify scoped access and review existing values.",
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
