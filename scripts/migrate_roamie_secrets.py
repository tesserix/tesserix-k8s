#!/usr/bin/env python3
"""Stage reviewed Roamie secrets with temporary exact-path write access."""

import argparse
import getpass
import json
import os
from pathlib import Path
import re
import sys

from migrate_fe3dr_reviewed import stage as stage_reviewed
from migrate_fe3dr_secret import MigrationError, OpenBao

POLICY = "roamie-migrate-reviewed"
TARGETS = {
    "dev-roamie-api-ocr-key": "roamie-development/app/roamie-api-ocr-key",
    "prod-agentic-registry-roamie-deploy-key": "roamie/app/roamie-registry-deploy-key",
    "prod-agentic-registry-roamie-deploy-key-sha256": "roamie/app/roamie-registry-deploy-key-sha256",
    "prod-document-intelligence-roamie-db-password": "roamie/app/roamie-document-intelligence-db-password",
    "prod-roamie-activities-oauth": "roamie/app/roamie-activities-oauth",
    "prod-roamie-agents-api-key": "roamie/app/roamie-agents-api-key",
    "prod-roamie-agents-gateway-clients": "roamie/app/roamie-agents-gateway-clients",
    "prod-roamie-api-ocr-key": "roamie/app/roamie-api-ocr-key",
    "prod-roamie-api-places-key": "roamie/app/roamie-api-places-key",
    "prod-roamie-delegation-key": "roamie/app/roamie-delegation-key",
    "prod-roamie-entry-guidance-oauth": "roamie/app/roamie-entry-guidance-oauth",
    "prod-roamie-exchange-oauth": "roamie/app/roamie-exchange-oauth",
    "prod-roamie-food-oauth": "roamie/app/roamie-food-oauth",
    "prod-roamie-manager-api-key": "roamie/app/roamie-manager-api-key",
    "prod-roamie-manager-gateway-clients": "roamie/app/roamie-manager-gateway-clients",
    "prod-roamie-manager-identity-key": "roamie/app/roamie-manager-identity-key",
    "prod-roamie-manager-subject": "roamie/app/roamie-manager-subject",
    "prod-roamie-mcp-api-token": "roamie/app/roamie-mcp-api-token",
    "prod-roamie-mcp-delegated-token": "roamie/app/roamie-mcp-delegated-token",
    "prod-roamie-memories-oauth": "roamie/app/roamie-memories-oauth",
    "prod-roamie-postgresql-password": "roamie/app/roamie-postgresql-password",
    "prod-roamie-postgresql-runtime-password": "roamie/app/roamie-postgresql-runtime-password",
    "prod-roamie-profile-signing-key": "roamie/app/roamie-profile-signing-key",
    "prod-roamie-routes-oauth": "roamie/app/roamie-routes-oauth",
    "prod-roamie-shopping-oauth": "roamie/app/roamie-shopping-oauth",
    "prod-roamie-travel-mcp-key": "roamie/app/roamie-travel-mcp-key",
    "prod-roamie-travel-schema-digest": "roamie/app/roamie-travel-schema-digest",
    "prod-roamie-trip-manager-oauth": "roamie/app/roamie-trip-manager-oauth",
    "prod-roamie-trip-oauth": "roamie/app/roamie-trip-oauth",
    "prod-roamie-weather-oauth": "roamie/app/roamie-weather-oauth",
}


def destination(source):
    if source not in TARGETS:
        raise ValueError("Source is not a reviewed Roamie candidate")
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
        plan, bao, account, record, policy=POLICY, target_namespace="roamie"
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
