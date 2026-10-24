import json
import os

from bind import request


def main():
    plan = json.loads(os.environ["PLAN"])
    cluster = request(
        "/apis/postgresql.cnpg.io/v1/namespaces/"
        + plan["namespace"]
        + "/clusters/"
        + plan["name"]
    )
    if cluster["metadata"]["uid"] != plan["currentUID"]:
        raise RuntimeError("replacement cluster identity changed")
    owner = {
        "apiVersion": "postgresql.cnpg.io/v1",
        "kind": "Cluster",
        "name": plan["name"],
        "uid": plan["currentUID"],
        "controller": True,
        "blockOwnerDeletion": True,
    }
    for child in plan["children"]:
        obj = request(child["path"], metadata=True)
        if obj["metadata"]["uid"] != child["uid"]:
            raise RuntimeError("retained child identity changed")
        refs = obj["metadata"].get("ownerReferences", [])
        if refs and refs != [owner]:
            raise RuntimeError("child has a different owner")
        request(
            child["path"],
            "PATCH",
            {
                "metadata": {
                    "uid": child["uid"],
                    "resourceVersion": obj["metadata"]["resourceVersion"],
                    "ownerReferences": [owner],
                }
            },
            metadata=True,
        )
    print(
        "Retained child ownership restored without replacing resources or credential values",
        flush=True,
    )


if __name__ == "__main__":
    main()
