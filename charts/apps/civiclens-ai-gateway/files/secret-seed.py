import json
import os
import secrets
import urllib.error
import urllib.request

BASE = "http://openbao.openbao.svc.cluster.local:8200/v1/"
TOKEN = "/var/run/secrets/openbao/token"


def call(token, path, body=None):
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
        return json.loads(response.read(65537) or "{}")


def present(token, key):
    try:
        call(token, "kv/data/" + key)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise
    return True


def seed(token, key):
    if present(token, key):
        return
    try:
        call(
            token,
            "kv/data/" + key,
            {"options": {"cas": 0}, "data": {"value": secrets.token_hex(32)}},
        )
    except urllib.error.HTTPError as error:
        if error.code != 400:
            raise
        # cas 0 refuses any existing version, including a soft-deleted one that reads as absent.
        if not present(token, key):
            raise RuntimeError(
                f"{key} was deleted; restore it instead of reseeding"
            ) from None


def main():
    with open(TOKEN) as source:
        jwt = source.read().strip()
    login = call(
        "", "auth/kubernetes/login", {"role": os.environ["OPENBAO_ROLE"], "jwt": jwt}
    )
    token = login["auth"]["client_token"]
    try:
        for key in os.environ["SEED_KEYS"].split(","):
            seed(token, key)
        print("CivicLens AI credential present; existing values preserved")
    finally:
        call(token, "auth/token/revoke-self", {})


if __name__ == "__main__":
    main()
