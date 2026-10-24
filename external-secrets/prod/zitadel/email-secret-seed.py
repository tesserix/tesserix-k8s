import json
import re
import secrets
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

BASE = "http://openbao.openbao.svc.cluster.local:8200/v1/"
KEY = "kv/data/zitadel/prod/app/zitadel-email-valkey-password"


def call(token: str, path: str, body: dict[str, Any] | None = None) -> Any:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["X-Vault-Token"] = token
    request = urllib.request.Request(
        BASE + path,
        headers=headers,
        data=None if body is None else json.dumps(body).encode(),
        method="GET" if body is None else "POST",
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        data = response.read(65537)
        if len(data) > 65536:
            raise ValueError("Oversized OpenBao response")
        return json.loads(data or "{}")


def present(token: str) -> bool:
    try:
        value = call(token, KEY)["data"]["data"]["value"]
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise
    if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{64}", value):
        raise ValueError("Existing password has an invalid format")
    return True


def seed(token: str) -> None:
    if present(token):
        return
    try:
        call(
            token,
            KEY,
            {"options": {"cas": 0}, "data": {"value": secrets.token_hex(32)}},
        )
    except urllib.error.HTTPError as error:
        if error.code != 400 or not present(token):
            raise


def main() -> None:
    jwt = Path("/var/run/secrets/openbao/token").read_text().strip()
    token = call(
        "",
        "auth/kubernetes/login",
        {"role": "seed-zitadel-email-production", "jwt": jwt},
    )["auth"]["client_token"]
    try:
        seed(token)
        print("OTP Valkey password present; existing value preserved")
    finally:
        call(token, "auth/token/revoke-self", {})


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        raise SystemExit("OTP secret seed failed; payloads withheld") from None
