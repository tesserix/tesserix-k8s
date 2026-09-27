#!/usr/bin/env python3
"""Stage reviewed fe3dr candidates using an exact-path temporary writer."""

import argparse
import base64
import getpass
import json
import os
from pathlib import Path
import re
import sys

from migrate_fe3dr_secret import (
    MigrationError,
    OpenBao,
    PROJECT,
    copy_secret,
    gcloud,
    validate_token,
)

POLICY = "fe3dr-migrate-reviewed"
STATIC_SUFFIXES = {
    "gip-web-api-key",
    "customer-client-secret",
    "business-client-secret",
    "internal-client-secret",
    "openexchangerates-app-id",
    "exchangerates-api-key",
    "google-maps-api-key",
    "mappls-client-id",
    "mappls-client-secret",
    "delivery-surge-pin-key",
    "jwt-secret",
    "jwt-refresh-secret",
    "session-encrypt-key",
    "apple-key-id",
    "apple-signin-private-key-b64",
    "admin-allowed-emails",
    "postgresql-password",
    "bff-internal-hmac-key",
    "google-weather-api-key",
    "support-hook-secret",
    "platform-admin-password",
    "cashfree-app-id",
    "cashfree-secret-key",
    "cashfree-test-app-id",
    "cashfree-test-secret-key",
    "cashfree-payout-client-id",
    "cashfree-payout-client-secret",
    "cashfree-payout-public-key",
    "cashfree-payout-test-client-id",
    "cashfree-payout-test-client-secret",
    "cashfree-payout-test-public-key",
    "pii-dek-wrapped",
    "pii-bidx-key",
}


def identifier(source):
    if source == "prod-support-platform-homechef-mcp-key":
        return "fe3dr-mcp-key"
    prefix = "prod-homechef-"
    if not source.startswith(prefix):
        raise ValueError("Source is not a reviewed production app candidate")
    suffix = source[len(prefix) :]
    if suffix not in STATIC_SUFFIXES and not re.fullmatch(
        r"vendor-payment-[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}-bank-(?:account-name|account-number|ifsc)",
        suffix,
    ):
        raise ValueError("Source is not a reviewed production app candidate")
    return "fe3dr-" + suffix


def validate_plan(plan):
    if not isinstance(plan, list) or not plan:
        raise ValueError("Plan must be a non-empty list")
    seen = set()
    for item in plan:
        name = identifier(item["source"])
        if item["source"] in seen or not re.fullmatch(r"[1-9][0-9]*", item["version"]):
            raise ValueError("Require unique sources and pinned numeric versions")
        seen.add(item["source"])
        targets = item["targets"]
        if not targets or len(targets) != len(set(targets)):
            raise ValueError("Targets must be non-empty and unique")
        for target in targets:
            if target not in {
                f"homechef/homechef-api/{name}",
                f"homechef/homechef-auth-bff/{name}",
            }:
                raise ValueError("Target must match the source and approved app prefix")


def policy_for(plan):
    validate_plan(plan)
    paths = sorted({target for item in plan for target in item["targets"]})
    return (
        "\n".join(
            f'path "kv/data/{path}" {{ capabilities = ["create", "read"] }}'
            for path in paths
        )
        + '\npath "auth/token/lookup-self" { capabilities = ["read"] }\npath "auth/token/revoke-self" { capabilities = ["update"] }\n'
    )


def stage(plan, bao, account, record):
    try:
        validate_token(bao.request("GET", "auth/token/lookup-self")["data"], POLICY)
        actual = (
            gcloud("auth", "list", "--filter=status:ACTIVE", "--format=value(account)")
            .decode()
            .strip()
        )
        if actual != account:
            raise MigrationError("Active account differs from expected account")
        print(f"Account: {account}; project: {PROJECT}; target namespaces: homechef")
        for item in plan:
            source, version = item["source"], item["version"]
            metadata = json.loads(
                gcloud(
                    "secrets",
                    "versions",
                    "describe",
                    version,
                    f"--secret={source}",
                    f"--project={PROJECT}",
                    "--format=json",
                )
            )
            if metadata.get("state") != "ENABLED" or not metadata.get(
                "name", ""
            ).endswith(f"/secrets/{source}/versions/{version}"):
                raise MigrationError("Source version not enabled or mismatched")
            value = base64.b64decode(
                gcloud(
                    "secrets",
                    "versions",
                    "access",
                    version,
                    f"--secret={source}",
                    f"--project={PROJECT}",
                    "--format=get(payload.data)",
                ).strip(),
                altchars=b"-_",
                validate=True,
            )
            for target in item["targets"]:
                state, copied_version = copy_secret(
                    bao.request, value, "kv/data/" + target
                )
                # Only metadata goes to the journal; flushed after every verified target.
                record.write(
                    json.dumps(
                        {
                            "source": source,
                            "source_version": version,
                            "target": target,
                            "destination_version": copied_version,
                            "result": state,
                            "equality": "PASS",
                        }
                    )
                    + "\n"
                )
                record.flush()
            print(
                f"Verified {len(item['targets'])} target(s); progress {plan.index(item) + 1}/{len(plan)}"
            )
    finally:
        bao.request("POST", "auth/token/revoke-self", {})
        print("Temporary writer token revoked")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument(
        "--policy",
        action="store_true",
        help="Print exact-path policy without accessing secrets",
    )
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
            print(
                f"PLAN: {len(plan)} sources; {sum(len(i['targets']) for i in plan)} exact targets. No reads/writes."
            )
        else:
            if not args.account or not args.journal:
                parser.error("--execute requires --account and --journal")
            token = os.environ.pop("BAO_TOKEN", "") or getpass.getpass(
                "Temporary OpenBao token: "
            )
            bao = OpenBao(args.bao_addr, token)
            with args.journal.open("a") as record:
                stage(plan, bao, args.account, record)
    except (MigrationError, ValueError, KeyError, TypeError, OSError):
        print(
            "Migration stopped; inspect metadata journal. Error details withheld.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
