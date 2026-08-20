from pathlib import Path

import yaml


ROOT = Path(__file__).parents[1]


def resource(documents: list[dict], kind: str, name: str) -> dict:
    return next(
        document
        for document in documents
        if document
        and document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


def test_growthbook_admin_password_is_materialized_for_the_seed_hook() -> None:
    documents = list(
        yaml.safe_load_all(
            (ROOT / "external-secrets/prod/growthbook/externalsecret.yaml").read_text()
        )
    )
    external_secret = resource(
        documents, "ExternalSecret", "growthbook-admin-secret"
    )

    assert external_secret["metadata"]["namespace"] == "growthbook"
    assert external_secret["spec"]["target"] == {
        "name": "growthbook-admin-secret",
        "creationPolicy": "Owner",
        "deletionPolicy": "Retain",
    }
    assert external_secret["spec"]["data"] == [
        {
            "secretKey": "password",
            "remoteRef": {"key": "prod-growthbook-admin-password"},
        }
    ]

    application = yaml.safe_load(
        (ROOT / "argocd/prod/infrastructure/growthbook.yaml").read_text()
    )
    values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
    assert values["featureSeeding"]["adminPasswordSecret"] == {
        "name": "growthbook-admin-secret",
        "key": "password",
    }
