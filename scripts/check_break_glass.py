#!/usr/bin/env python3
"""Assert the OpenBao break-glass path still works.

`docs/runbooks/openbao-break-glass.md` describes how to reach secrets when the
console is unavailable. A runbook nobody executes is a document, not a control —
and this estate has the evidence: the `root_token` stored in
`prod-openbao-recovery-keys` had been REVOKED since the first bootstrap run
(the Job revokes it deliberately), and nothing noticed until someone tried to
use it during the audit for tesserix-home#462. The failure surfaced as a bare
`permission denied`, which during an incident reads as "I lack access" rather
than "this credential was destroyed on purpose".

So this check EXERCISES the path rather than inspecting its configuration. A
check that only confirmed the role existed would have passed for months while
break-glass was dead.

It mints a bootstrap token on every run, which is a privileged credential on a
schedule and is the deliberate cost of the above. Three things bound it: the
role's own 10-minute TTL, an explicit revoke at the end, and assertion 3 below,
which fails if that token can ever read a secret value.

Read-only with respect to secrets: it never reads a value, and it writes no
policy or role. Run locally against a port-forward with:

    kubectl -n openbao port-forward svc/openbao-active 8200:8200
    BAO_ADDR=http://127.0.0.1:8200 python3 scripts/check_break_glass.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

BAO_ADDR = os.environ.get("BAO_ADDR", "http://127.0.0.1:8200")
PROJECT = os.environ.get("GCP_PROJECT_ID", "tesseracthub-480811")
RECOVERY_SECRET = "prod-openbao-recovery-keys"
EXPECTED_POLICIES = {"bootstrap", "default"}
EXPECTED_RECOVERY_SHARES = 5

# A path that exists and that the bootstrap identity must NOT be able to read.
# Reading is what the console does; administering is what bootstrap does.
FORBIDDEN_READ = "kv/data/cloudflared/cloudflared/tunnel"


def api(path: str, token: str | None = None, method: str = "GET", body: dict | None = None):
    req = urllib.request.Request(
        f"{BAO_ADDR}/v1/{path}",
        method=method,
        data=json.dumps(body).encode() if body else None,
    )
    if token:
        req.add_header("X-Vault-Token", token)
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, {"errors": [raw.decode(errors="replace")[:200]]}
    except Exception as e:  # noqa: BLE001 - network shape varies, message is what matters
        return 0, {"errors": [str(e)]}


def gcloud_secret(name: str) -> bytes:
    return subprocess.run(
        ["gcloud", "secrets", "versions", "access", "latest", "--secret", name, "--project", PROJECT],
        capture_output=True,
    ).stdout


def main() -> int:
    failures: list[str] = []
    notes: list[str] = []

    # 1. Reachable and unsealed. A sealed OpenBao is a different incident, but
    #    break-glass cannot work through it either, so it fails here rather than
    #    confusingly two steps later.
    status, health = api("sys/health")
    if not health.get("initialized") or health.get("sealed") is not False:
        failures.append(f"OpenBao not usable: initialized={health.get('initialized')} sealed={health.get('sealed')}")
        print_report(failures, notes)
        return 1
    notes.append(f"reachable, unsealed, version {health.get('version')}")

    # 2. The documented way in actually authenticates.
    sa_token = subprocess.run(
        ["kubectl", "-n", "openbao", "create", "token", "openbao-bootstrap", "--duration=10m"],
        capture_output=True, text=True,
    ).stdout.strip()
    if not sa_token:
        failures.append("could not mint a Kubernetes token for serviceaccount/openbao-bootstrap")
        print_report(failures, notes)
        return 1

    status, login = api("auth/kubernetes/login", method="POST", body={"role": "bootstrap", "jwt": sa_token})
    auth = login.get("auth") or {}
    bao_token = auth.get("client_token")
    if not bao_token:
        failures.append(f"auth/kubernetes login as role=bootstrap failed: {login.get('errors')}")
        print_report(failures, notes)
        return 1

    got = set(auth.get("policies") or [])
    if got != EXPECTED_POLICIES:
        failures.append(f"bootstrap login returned policies {sorted(got)}, expected {sorted(EXPECTED_POLICIES)}")
    notes.append(f"login ok, policies {sorted(got)}, ttl {auth.get('lease_duration')}s")

    try:
        # 3. The administrative surface is reachable...
        status, mounts = api("sys/mounts", bao_token)
        if status != 200:
            failures.append(f"bootstrap token cannot read sys/mounts ({status}) — the path is broken")

        # ...and the boundary still holds. This assertion is why the check is
        # worth minting a token for: if it ever passes, the bootstrap identity
        # has gained the ability to read secrets, which is the property the
        # whole authorization model exists to prevent.
        status, secret = api(FORBIDDEN_READ, bao_token)
        if status == 200:
            failures.append(
                f"SECURITY: the bootstrap token READ a secret value at {FORBIDDEN_READ}. "
                "It administers OpenBao and must not be able to read from it."
            )
        else:
            notes.append(f"boundary holds: reading a value refused ({status})")
    finally:
        # 4. Close the window, and prove it closed.
        api("auth/token/revoke-self", bao_token, method="POST")
        status, _ = api("auth/token/lookup-self", bao_token)
        if status == 200:
            failures.append("revoke-self did not revoke the token — a privileged token is still live")
        else:
            notes.append("token revoked")

    # 5. The stored recovery material is what the runbook says it is.
    raw = gcloud_secret(RECOVERY_SECRET)
    if not raw:
        failures.append(f"{RECOVERY_SECRET} is unreadable — the recovery shares may be gone")
    else:
        try:
            stored = json.loads(raw)
        except json.JSONDecodeError:
            failures.append(f"{RECOVERY_SECRET} is not JSON")
            stored = {}
        shares = stored.get("recovery_keys_base64") or []
        if len(shares) != EXPECTED_RECOVERY_SHARES:
            failures.append(f"{RECOVERY_SECRET} holds {len(shares)} recovery shares, expected {EXPECTED_RECOVERY_SHARES}")
        else:
            notes.append(f"{EXPECTED_RECOVERY_SHARES} recovery shares present")

        # The trap this check was written because of. While the field exists it
        # is the first thing an operator reaches for, and it is revoked. This is
        # a WARNING rather than a failure so the check stays green once the
        # field is removed, and stays loud until it is.
        if stored.get("root_token"):
            notes.append(
                "WARNING: root_token is still present in the secret and is revoked by design "
                "(the bootstrap Job calls revoke-self). It is a dead end an operator will try first "
                "during an incident — remove the field. See tesserix-home#462."
            )

    print_report(failures, notes)
    return 1 if failures else 0


def print_report(failures: list[str], notes: list[str]) -> None:
    for n in notes:
        print(f"  ok: {n}" if not n.startswith("WARNING") else f"  {n}")
    if failures:
        print("\nBREAK-GLASS CHECK FAILED\n", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print(
            "\nThe path in docs/runbooks/openbao-break-glass.md no longer works as written. "
            "Fix the path or the runbook before the next incident needs it.",
            file=sys.stderr,
        )
    else:
        print("\nOK: the break-glass path in docs/runbooks/openbao-break-glass.md still works.")


if __name__ == "__main__":
    raise SystemExit(main())
