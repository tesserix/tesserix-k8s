"""Run inside DevAI with a private, archived row snapshot and values on stdin."""

import asyncio
import hashlib
import json
import re
import sys
from typing import Any


def destination(row: dict[str, Any], field: str, nonce: str) -> str:
    if (
        row["scope"] != "user"
        or not row["scope_id"]
        or row["connector_key"] != "llm"
        or row["instance_id"] != "default"
        or field not in {"openai_api_key", "anthropic_api_key"}
        or not re.fullmatch(r"[a-f0-9]{12}", nonce)
    ):
        raise ValueError("Unreviewed user credential mapping")
    owner = hashlib.sha256(f"user:{row['scope_id']}".encode()).hexdigest()[:32]
    logical = f"devai-user-{row['scope_id']}-llm-default-{field}"
    name = re.sub(r"[^a-z0-9-]+", "-", logical.lower()).strip("-")[:100]
    return f"devai/devai-api/{owner}/{name}-migration-{nonce}"


def replacement(row: dict[str, Any], paths: dict[str, str]) -> dict[str, str]:
    refs = dict(row["secret_refs"])
    if not paths:
        raise ValueError("Empty migration")
    for field, path in paths.items():
        source = f"devai-user-{row['scope_id']}-llm-default-{field}"
        if refs.get(field) != source or path != destination(row, field, path[-12:]):
            raise ValueError("Source reference or destination owner changed")
        refs[field] = path
    return refs


async def migrate(payload: dict[str, Any]) -> None:
    import asyncpg
    from devai.adapters.secrets.openbao import OpenBaoSecretsAdapter
    from devai.config import Settings

    row = payload["row"]
    values = payload["values"]
    paths = {field: destination(row, field, payload["nonce"]) for field in values}
    refs = replacement(row, paths)
    settings = Settings()
    adapter = OpenBaoSecretsAdapter(settings)
    conn = await asyncpg.connect(settings.database_url)
    key = [row[k] for k in ["scope", "scope_id", "connector_key", "instance_id"]]
    query = (
        "SELECT to_jsonb(t) FROM user_settings t WHERE scope=$1 AND scope_id=$2 "
        "AND connector_key=$3 AND instance_id=$4"
    )
    expected_after = row | {"secret_refs": refs}
    try:
        current = json.loads(await conn.fetchval(query, *key))
        if current not in (row, expected_after):
            raise ValueError("Row changed since archived snapshot")
        if not await adapter.can_write():
            raise ValueError("Workload broker unavailable")
        for field, value in values.items():
            if not isinstance(value, str) or not value:
                raise ValueError("Empty or non-string credential")
            found = await adapter.get_secret(paths[field])
            if found is not None and found != value:
                raise ValueError("Destination differs; refusing overwrite")
            if found is None:
                # Unique migration names avoid concurrent canonical application writes.
                ref = await adapter.set_secret(
                    paths[field].split("/")[-1],
                    value,
                    labels={
                        "scope": row["scope"],
                        "scope_id": row["scope_id"],
                        "connector": row["connector_key"],
                        "field": field,
                    },
                )
                if ref.name != paths[field]:
                    raise ValueError("Broker returned unexpected destination")
            if await adapter.get_secret(paths[field]) != value:
                raise ValueError("Credential readback differs")
        async with conn.transaction(isolation="serializable"):
            await conn.execute("SET LOCAL lock_timeout = '5s'")
            current = json.loads(await conn.fetchval(query + " FOR UPDATE", *key))
            if current == row:
                result = await conn.execute(
                    "UPDATE user_settings SET secret_refs=$5::jsonb WHERE scope=$1 "
                    "AND scope_id=$2 AND connector_key=$3 AND instance_id=$4 "
                    "AND secret_refs=$6::jsonb",
                    *key,
                    json.dumps(refs),
                    json.dumps(row["secret_refs"]),
                )
                if result != "UPDATE 1":
                    raise ValueError("Reference compare-and-swap failed")
            elif current != expected_after:
                raise ValueError("Concurrent row update; migration aborted")
        if json.loads(await conn.fetchval(query, *key)) != expected_after:
            raise ValueError("Post-commit row verification failed")
        for field, value in values.items():
            if await adapter.get_secret(refs[field]) != value:
                raise ValueError("Post-commit runtime read failed")
        print(
            f"User credentials verified: {len(values)}; references committed; other row fields preserved"
        )
    finally:
        await conn.close()
        await adapter.close()


if __name__ == "__main__":
    try:
        asyncio.run(migrate(json.load(sys.stdin)))
    except Exception:
        print("User reference migration stopped; diagnostics withheld", file=sys.stderr)
        raise SystemExit(1) from None
