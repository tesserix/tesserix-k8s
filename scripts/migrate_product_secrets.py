#!/usr/bin/env python3
"""Stage reviewed product application secrets under temporary exact-path access."""

import argparse
import getpass
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, TextIO

from migrate_fe3dr_reviewed import stage as stage_reviewed
from migrate_fe3dr_secret import MigrationError, OpenBao

CATALOG = Path(__file__).with_name("product-secret-targets.json")


def targets_for(product: str) -> dict[str, str]:
    catalog = json.loads(CATALOG.read_text())
    if product not in catalog:
        raise ValueError("Product has no reviewed application inventory")
    return dict(catalog[product])


def validate_plan(product: str, plan: list[dict[str, Any]]) -> None:
    targets = targets_for(product)
    if not isinstance(plan, list) or not plan:
        raise ValueError("Require a nonempty plan")
    seen = set()
    for item in plan:
        source = item["source"]
        if source not in targets or source in seen:
            raise ValueError("Require unique reviewed application sources")
        if not re.fullmatch(r"[1-9][0-9]*", item["version"]):
            raise ValueError("Require pinned numeric versions")
        if item["targets"] != [targets[source]]:
            raise ValueError("Destination differs from reviewed source/environment")
        seen.add(source)


def policy_for(product: str, plan: list[dict[str, Any]]) -> str:
    validate_plan(product, plan)
    return (
        "\n".join(
            f'path "kv/data/{item["targets"][0]}" {{ capabilities = ["create", "read"] }}'
            for item in plan
        )
        + '\npath "auth/token/lookup-self" { capabilities = ["read"] }\npath "auth/token/revoke-self" { capabilities = ["update"] }\n'
    )


def stage(
    product: str, plan: list[dict[str, Any]], bao: Any, account: str, record: TextIO
) -> None:
    validate_plan(product, plan)
    stage_reviewed(
        plan,
        bao,
        account,
        record,
        policy=f"{product}-migrate-reviewed",
        target_namespace=product,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--product", required=True)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--policy", action="store_true")
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--account")
    parser.add_argument("--journal", type=Path)
    parser.add_argument("--bao-addr", default="http://127.0.0.1:18200")
    args = parser.parse_args()
    try:
        plan = json.loads(args.plan.read_text())
        validate_plan(args.product, plan)
        if args.policy:
            print(policy_for(args.product, plan))
        elif not args.execute:
            print(f"PLAN: {len(plan)} sources; no reads or writes")
        else:
            if not args.account or not args.journal:
                parser.error("--execute requires --account and --journal")
            token = os.environ.pop("BAO_TOKEN", "") or getpass.getpass(
                "Temporary OpenBao token: "
            )
            with args.journal.open("a") as journal:
                stage(
                    args.product,
                    plan,
                    OpenBao(args.bao_addr, token),
                    args.account,
                    journal,
                )
    except (MigrationError, ValueError, KeyError, TypeError, OSError):
        print(
            "Migration stopped; inspect metadata journal. Details withheld.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
