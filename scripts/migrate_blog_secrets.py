#!/usr/bin/env python3
"""Stage reviewed Blog secrets with temporary exact-path write access."""

import argparse
import getpass
import json
import os
from pathlib import Path
import re
import sys

from migrate_fe3dr_reviewed import stage as stage_reviewed
from migrate_fe3dr_secret import MigrationError, OpenBao

POLICY = "blog-migrate-reviewed"
TARGETS = {
    "prod-blog-keycloak-client-secret": "blog/app/blog-keycloak-client-secret",
    "prod-blog-mongodb-root-password": "blog/app/blog-mongodb-root-password",
    "prod-blog-mongodb-uri": "blog/app/blog-mongodb-uri",
    "prod-blog-oidc-client-secret": "blog/app/blog-oidc-client-secret",
    "prod-blog-session-secret": "blog/app/blog-session-secret",
}


def destination(source):
    if source not in TARGETS:
        raise ValueError("Source is not a reviewed Blog candidate")
    return TARGETS[source]


def validate_plan(plan):
    if not isinstance(plan, list) or not plan:
        raise ValueError("Require a nonempty plan")
    seen = set()
    for item in plan:
        if item["source"] in seen or not re.fullmatch(r"[1-9][0-9]*", item["version"]):
            raise ValueError("Require unique sources and pinned numeric versions")
        seen.add(item["source"])
        if item["targets"] != [destination(item["source"])]:
            raise ValueError("Destination differs from approved source/environment")


def policy_for(plan):
    validate_plan(plan)
    return (
        "\n".join(
            'path "kv/data/'
            + item["targets"][0]
            + '" { capabilities = ["create", "read"] }'
            for item in plan
        )
        + '\npath "auth/token/lookup-self" { capabilities = ["read"] }\npath "auth/token/revoke-self" { capabilities = ["update"] }\n'
    )


def stage(plan, bao, account, record):
    validate_plan(plan)
    return stage_reviewed(
        plan, bao, account, record, policy=POLICY, target_namespace="tesserix"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--policy", action="store_true")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--account")
    parser.add_argument("--journal", type=Path)
    parser.add_argument("--bao-addr", default="http://127.0.0.1:18200")
    args = parser.parse_args()
    try:
        plan = json.loads(args.plan.read_text())
        validate_plan(plan)
        if args.policy:
            print(policy_for(plan))
        elif not args.execute:
            print(f"PLAN: {len(plan)} sources; no reads or writes")
        else:
            if not args.account or not args.journal:
                parser.error("--execute requires --account and --journal")
            token = os.environ.pop("BAO_TOKEN", "") or getpass.getpass(
                "Temporary OpenBao token: "
            )
            with args.journal.open("a") as journal:
                stage(plan, OpenBao(args.bao_addr, token), args.account, journal)
    except (MigrationError, ValueError, KeyError, TypeError, OSError):
        print(
            "Migration stopped; inspect metadata journal. Details withheld.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
