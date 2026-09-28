import json

import yaml
from test_homechef_openbao_access import ROOT, resource


def test_cloudflare_has_reviewed_copy_destination():
    assert json.loads((ROOT / "scripts/product-secret-targets.json").read_text())[
        "cloudflare"
    ] == {"prod-cloudflare-api-token": "cloudflare/app/cloudflare-api-token"}


def test_cloudflare_consumers_continue_reading_retained_gcp_original():
    for ns in ["cert-manager", "external-dns"]:
        docs = list(
            yaml.safe_load_all(
                (ROOT / f"external-secrets/prod/{ns}/externalsecret.yaml").read_text()
            )
        )
        es = resource(docs, "ExternalSecret", "cloudflare-api-token")
        assert es["spec"]["secretStoreRef"] == {
            "name": "gcp-secret-store",
            "kind": "ClusterSecretStore",
        }
        assert es["spec"]["data"] == [
            {
                "secretKey": "api-token",
                "remoteRef": {"key": "prod-cloudflare-api-token"},
            }
        ]
    main = (ROOT / "terraform-new/stacks/03-storage/main.tf").read_text()
    retired = main.split("retired_application_secret_ids = toset([", 1)[1].split(
        "])", 1
    )[0]
    assert '"prod-cloudflare-api-token"' not in retired
