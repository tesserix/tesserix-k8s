#!/usr/bin/env python3
"""Stage reviewed DevAI secrets with temporary exact-path write access."""

import argparse
import getpass
import json
import os
from pathlib import Path
import re
import sys

from migrate_fe3dr_reviewed import stage as stage_reviewed
from migrate_fe3dr_secret import MigrationError, OpenBao

POLICY = "devai-migrate-reviewed"
TARGETS = {
    "prod-agentic-registry-devai-deploy-key": "devai/app/devai-registry-deploy-key",
    "prod-agentic-registry-devai-deploy-key-sha256": "devai/app/devai-registry-deploy-key-sha256",
    "prod-devai-admin-allowed-emails": "devai/app/devai-admin-allowed-emails",
    "prod-devai-anthropic-api-key": "devai/app/devai-anthropic-api-key",
    "prod-devai-auth-bff-session-secret": "devai/app/devai-auth-bff-session-secret",
    "prod-devai-auth-bff-shared-secret": "devai/app/devai-auth-bff-shared-secret",
    "prod-devai-bff-csrf-secret": "devai/app/devai-bff-csrf-secret",
    "prod-devai-bff-internal-hmac-key": "devai/app/devai-bff-internal-hmac-key",
    "prod-devai-cloudflare-account-id": "devai/app/devai-cloudflare-account-id",
    "prod-devai-cloudflare-api-token": "devai/app/devai-cloudflare-api-token",
    "prod-devai-evals-postgresql-password": "devai/app/devai-evals-postgresql-password",
    "prod-devai-gemini-api-key": "devai/app/devai-gemini-api-key",
    "prod-devai-gip-alm-tenant-id": "devai/app/devai-gip-alm-tenant-id",
    "prod-devai-gip-sre-tenant-id": "devai/app/devai-gip-sre-tenant-id",
    "prod-devai-gip-web-api-key": "devai/app/devai-gip-web-api-key",
    "prod-devai-github-app-id": "devai/app/devai-github-app-id",
    "prod-devai-github-app-installation-id": "devai/app/devai-github-app-installation-id",
    "prod-devai-github-app-private-key": "devai/app/devai-github-app-private-key",
    "prod-devai-github-client-id": "devai/app/devai-github-client-id",
    "prod-devai-github-client-secret": "devai/app/devai-github-client-secret",
    "prod-devai-github-oauth-client-id": "devai/app/devai-github-oauth-client-id",
    "prod-devai-github-oauth-client-secret": "devai/app/devai-github-oauth-client-secret",
    "prod-devai-github-pat": "devai/app/devai-github-pat",
    "prod-devai-github-webhook-secret": "devai/app/devai-github-webhook-secret",
    "prod-devai-groq-api-key": "devai/app/devai-groq-api-key",
    "prod-devai-keycloak-client-secret": "devai/app/devai-keycloak-client-secret",
    "prod-devai-langfuse-public-key": "devai/app/devai-langfuse-public-key",
    "prod-devai-langfuse-secret-key": "devai/app/devai-langfuse-secret-key",
    "prod-devai-langsmith-api-key": "devai/app/devai-langsmith-api-key",
    "prod-devai-mcp-hub-service-token": "devai/app/devai-mcp-hub-service-token",
    "prod-devai-openai-api-key": "devai/app/devai-openai-api-key",
    "prod-devai-postgresql-password": "devai/app/devai-postgresql-password",
    "prod-devai-session-encrypt-key": "devai/app/devai-session-encrypt-key",
    "prod-devai-temporal-payload-key": "devai/app/devai-temporal-payload-key",
    "prod-devai-vertex-api-key": "devai/app/devai-vertex-api-key",
    "prod-keycloak-devai-bff-client-secret": "devai/app/devai-keycloak-bff-client-secret",
    "prod-keycloak-devai-sre-bff-client-secret": "devai/app/devai-keycloak-sre-bff-client-secret",
    "prod-openpanel-devai-client-id": "devai/app/devai-openpanel-client-id",
}


def destination(source):
    if source not in TARGETS:
        raise ValueError("Source is not a reviewed DevAI candidate")
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
        plan, bao, account, record, policy=POLICY, target_namespace="devai"
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
