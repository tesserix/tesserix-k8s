#!/usr/bin/env python3
"""Stage reviewed Kora secrets with temporary exact-path write access."""

import argparse
import getpass
import json
import os
from pathlib import Path
import re
import sys

from migrate_fe3dr_reviewed import stage as stage_reviewed
from migrate_fe3dr_secret import MigrationError, OpenBao

POLICY = "kora-migrate-reviewed"
TARGETS = {'dev-kora-document-intelligence-signing-key': 'kora-development/app/kora-document-intelligence-signing-key',
 'dev-kora-langfuse-org-public-key': 'kora-development/app/kora-langfuse-org-public-key',
 'dev-kora-langfuse-org-secret-key': 'kora-development/app/kora-langfuse-org-secret-key',
 'dev-kora-langfuse-public-key': 'kora-development/app/kora-langfuse-public-key',
 'dev-kora-langfuse-secret-key': 'kora-development/app/kora-langfuse-secret-key',
 'dev-kora-ocr-workload-identity-keys': 'kora-development/app/kora-ocr-workload-identity-keys',
 'prod-agentic-registry-kora-deploy-key': 'kora/app/kora-registry-deploy-key',
 'prod-agentic-registry-kora-deploy-key-sha256': 'kora/app/kora-registry-deploy-key-sha256',
 'prod-kora-ai-agents-api-key': 'kora/app/kora-ai-agents-api-key',
 'prod-kora-ai-gateway-api-key': 'kora/app/kora-ai-gateway-api-key',
 'prod-kora-api-platform-admin': 'kora/app/kora-api-platform-admin',
 'prod-kora-apple-key-id': 'kora/app/kora-apple-key-id',
 'prod-kora-apple-private-key': 'kora/app/kora-apple-private-key',
 'prod-kora-apple-team-id': 'kora/app/kora-apple-team-id',
 'prod-kora-bff-internal-hmac-key': 'kora/app/kora-bff-internal-hmac-key',
 'prod-kora-database-url': 'kora/app/kora-database-url',
 'prod-kora-expo-access-token': 'kora/app/kora-expo-access-token',
 'prod-kora-gemini-api-key': 'kora/app/kora-gemini-api-key',
 'prod-kora-langfuse-org-public-key': 'kora/app/kora-langfuse-org-public-key',
 'prod-kora-langfuse-org-secret-key': 'kora/app/kora-langfuse-org-secret-key',
 'prod-kora-langfuse-public-key': 'kora/app/kora-langfuse-public-key',
 'prod-kora-langfuse-secret-key': 'kora/app/kora-langfuse-secret-key',
 'prod-kora-mcp-internal-key': 'kora/app/kora-mcp-internal-key',
 'prod-kora-ocr-workload-identity-keys': 'kora/app/kora-ocr-workload-identity-keys',
 'prod-kora-openai-api-key': 'kora/app/kora-openai-api-key',
 'prod-kora-postgresql-password': 'kora/app/kora-postgresql-password',
 'prod-kora-sandbox-anonymization-salt': 'kora/app/kora-sandbox-anonymization-salt',
 'prod-kora-sandbox-reader-password': 'kora/app/kora-sandbox-reader-password',
 'prod-kora-sandbox-sync-source-url': 'kora/app/kora-sandbox-sync-source-url',
 'prod-kora-sandbox-sync-target-url': 'kora/app/kora-sandbox-sync-target-url',
 'prod-kora-vertex-api-key': 'kora/app/kora-vertex-api-key',
 'prod-support-platform-kora-mcp-key': 'kora/app/kora-mcp-key'}


def destination(source):
    if source not in TARGETS:
        raise ValueError("Source is not a reviewed Kora candidate")
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
        plan, bao, account, record, policy=POLICY, target_namespace="kora"
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
