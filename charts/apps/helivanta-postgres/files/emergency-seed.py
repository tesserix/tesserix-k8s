import json
import os
import secrets
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

BASE = "http://openbao.openbao.svc.cluster.local:8200/v1/"
PRODUCT = os.environ.get("WORKER_PRODUCT", "emergency")
if PRODUCT not in {"emergency", "privacy"}:
    raise SystemExit("Unsupported worker credential scope")
ROLE = f"seed-helivanta-{PRODUCT}-worker-production"
DATA = f"kv/data/helivanta/production/helivanta-{PRODUCT}-worker-db-password"
METADATA = DATA.replace("/data/", "/metadata/", 1)


class Client:
    def __init__(self, base: str, token: str = "") -> None:
        self.base = base
        self.token = token

    def call(
        self, path: str, data: dict[str, Any] | None = None, method: str | None = None
    ) -> dict[str, Any]:
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["X-Vault-Token"] = self.token
        request = urllib.request.Request(
            self.base + path,
            headers=headers,
            data=None if data is None else json.dumps(data).encode(),
            method=method,
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            result: dict[str, Any] = json.loads(response.read(65537) or "{}")
            return result


def exists(client: Client) -> bool:
    try:
        metadata = client.call(METADATA)["data"]
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise
    version = metadata["versions"][str(metadata["current_version"])]
    if version["destroyed"] or version["deletion_time"]:
        raise RuntimeError("existing credential requires approved recovery")
    return True


def initialize(client: Client) -> None:
    if exists(client):
        return
    try:
        client.call(
            DATA,
            {"options": {"cas": 0}, "data": {"password": secrets.token_urlsafe(48)}},
        )
    except urllib.error.HTTPError as error:
        if error.code not in (400, 403) or not exists(client):
            raise


def main() -> None:
    jwt = Path("/var/run/secrets/openbao/token").read_text().strip()
    token = Client(BASE).call("auth/kubernetes/login", {"role": ROLE, "jwt": jwt})[
        "auth"
    ]["client_token"]
    client = Client(BASE, token)
    try:
        initialize(client)
        print("Worker credential initialized; existing versions preserved")
    finally:
        client.call("auth/token/revoke-self", {})


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, RuntimeError):
        raise SystemExit(
            "Worker credential initialization unavailable; payloads withheld"
        ) from None
