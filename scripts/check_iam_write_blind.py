#!/usr/bin/env python3
"""Assert the console's write-blind IAM role still matches what Git declares.

`tests/test_secret_manager_write_blind.py` pins what the REPOSITORY says. This
script pins what GCP actually has, and compares the two. They answer different
questions and both are needed: the test catches someone widening the role in a
pull request, this catches someone widening it in the Cloud Console, where
there is no diff to review and no check to fail.

That second path is the one the guarantee actually rests on. Atlantis autoplans
a stack only `when_modified` its own `*.tf` or the shared tfvars, so the 06
stack is not planned by an unrelated pull request, and nothing else runs
`terraform plan` on a schedule. Before this script, a console click adding
`secretmanager.versions.access` produced no diff, no failing check and no
alert — the console would simply gain the ability to read every secret payload
in the project while looking exactly as it does now.

The declared permission list is READ FROM TERRAFORM rather than repeated here.
A third hardcoded copy would be a third thing to keep in step, and the one most
likely to be updated last — this script would then pass while disagreeing with
the stack it exists to defend.

Read-only: it calls `gcloud ... describe` and `get-iam-policy` and never
mutates. Requires `roles/iam.roleViewer` and the ability to read the project
IAM policy; the CI service account has both.

Run locally with an authenticated gcloud:
    python3 scripts/check_iam_write_blind.py
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

PROJECT_ID = "tesseracthub-480811"
ROLE_ID = "secretManagerWriteBlind"
QUALIFIED_ROLE = f"projects/{PROJECT_ID}/roles/{ROLE_ID}"
CONSOLE_SA = f"secret-service@{PROJECT_ID}.iam.gserviceaccount.com"

STACK = Path("terraform-new/stacks/06-workload-identity/main.tf")

# The only permission that returns a secret's bytes. Every other `versions.*`
# verb manipulates a version without handing back the payload. The wildcards
# would grant it transitively.
PAYLOAD_READING = {
    "secretmanager.versions.access",
    "secretmanager.*",
    "*",
}


def _gcloud(*args: str) -> str:
    result = subprocess.run(
        ["gcloud", *args, f"--project={PROJECT_ID}", "--format=json"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"gcloud {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout


def declared_permissions() -> set[str]:
    """The permission list as the Terraform stack declares it."""
    block = re.search(
        r'resource\s+"google_project_iam_custom_role"\s+"secret_manager_write_blind"\s*\{(.*?)\n\}',
        STACK.read_text(),
        re.DOTALL,
    )
    if not block:
        raise SystemExit(f"write-blind custom role is no longer declared in {STACK}")
    return set(re.findall(r'"(secretmanager\.[^"]+)"', block.group(1)))


def live_permissions() -> set[str]:
    role = json.loads(_gcloud("iam", "roles", "describe", ROLE_ID))
    return set(role.get("includedPermissions") or [])


def live_roles_for_console_sa() -> list[str]:
    policy = json.loads(_gcloud("projects", "get-iam-policy", PROJECT_ID))
    member = f"serviceAccount:{CONSOLE_SA}"
    return sorted(
        b["role"] for b in policy.get("bindings", []) if member in (b.get("members") or [])
    )


def main() -> int:
    failures: list[str] = []

    declared = declared_permissions()
    live = live_permissions()

    # 1. Live must match Git exactly. Reported in both directions: a permission
    #    live-but-undeclared is the silent widening this exists to catch, and a
    #    permission declared-but-absent means an apply never landed, so the
    #    stack is not describing reality either.
    if declared != live:
        for perm in sorted(live - declared):
            failures.append(f"live role has {perm!r}, which {STACK} does not declare")
        for perm in sorted(declared - live):
            failures.append(f"{STACK} declares {perm!r}, which the live role does not have")

    # 2. Stated independently of the comparison above. If someone widens BOTH
    #    the stack and the live role in step, check 1 passes — they agree. This
    #    one still fails, because the property is not "Git and GCP agree", it is
    #    "the console cannot read a payload".
    leaks = live & PAYLOAD_READING
    if leaks:
        failures.append(
            f"live role grants payload-reading permission(s) {sorted(leaks)} — "
            "the console can now read every secret in the project"
        )

    # 3. A role that excludes `versions.access` protects nothing if a second
    #    role granting it is bound alongside.
    roles = live_roles_for_console_sa()
    if roles != [QUALIFIED_ROLE]:
        failures.append(
            f"{CONSOLE_SA} holds {roles}, expected exactly [{QUALIFIED_ROLE!r}]"
        )

    if failures:
        print("IAM DRIFT DETECTED\n", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print(
            "\nSee tesserix-home#465. If this change was intended, change the stack "
            "and let Atlantis apply it, rather than editing IAM in the Cloud Console.",
            file=sys.stderr,
        )
        return 1

    print(f"OK: write-blind role matches {STACK} ({len(live)} permissions)")
    print(f"OK: no payload-reading permission present")
    print(f"OK: {CONSOLE_SA} holds only the write-blind role")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
