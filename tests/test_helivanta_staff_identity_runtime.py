from test_helivanta_clinical_consent import named, render


def test_staff_identity_is_disabled_without_a_dedicated_runtime_configuration():
    rows = render("helivanta-api")
    pod = named(rows, "Deployment", "helivanta-api")["spec"]["template"]["spec"]
    assert not any(e["name"].startswith("ORGANIZATION_IDENTITY_") for e in pod["containers"][0]["env"])
    assert not any(r["kind"] == "SecretStore" and r["metadata"]["name"] == "helivanta-onboarding-client" for r in rows)


def test_staff_identity_mounts_only_its_product_machine_credential():
    rows = render("helivanta-api", "organizationIdentity.enabled=true", "organizationIdentity.tokenProjectID=synthetic-onboarding-project")
    pod = named(rows, "Deployment", "helivanta-api")["spec"]["template"]["spec"]
    api = pod["containers"][0]
    env = {e["name"]: e.get("value") for e in api["env"]}
    assert {k:v for k,v in env.items() if k.startswith("ORGANIZATION_IDENTITY_")} == {
        "ORGANIZATION_IDENTITY_URL": "https://onboard.tesserix.app",
        "ORGANIZATION_IDENTITY_PRODUCT_KEY": "helivanta",
        "ORGANIZATION_IDENTITY_TOKEN_PROJECT_ID": "synthetic-onboarding-project",
        "ORGANIZATION_IDENTITY_CLIENT_ID": "helivanta-onboarding-client",
        "ORGANIZATION_IDENTITY_CLIENT_SECRET_FILE": "/var/run/organization-identity/client-secret",
    }
    mount = next(m for m in api["volumeMounts"] if m["name"] == "organization-identity")
    assert mount == {"name":"organization-identity", "mountPath":"/var/run/organization-identity", "readOnly": True}
    volume = next(v for v in pod["volumes"] if v["name"] == "organization-identity")
    assert volume["secret"] == {"secretName":"helivanta-onboarding-client", "defaultMode": 0o440, "items":[{"key":"client-secret", "path":"client-secret"}]}
    store = named(rows, "SecretStore", "helivanta-onboarding-client")["spec"]["provider"]["vault"]
    assert store["path"] == "kv" and store["version"] == "v2"
    assert store["auth"]["kubernetes"] == {"mountPath":"kubernetes", "role":"helivanta-onboarding-client-reader", "serviceAccountRef":{"name":"helivanta-api"}}
    secret = named(rows, "ExternalSecret", "helivanta-onboarding-client")["spec"]
    assert secret["secretStoreRef"] == {"name":"helivanta-onboarding-client", "kind":"SecretStore"}
    assert secret["data"] == [{"secretKey":"client-secret", "remoteRef":{"key":"helivanta/prod/app/helivanta-onboarding-client", "property":"value"}}]
    migration = next(r for r in rows if r["kind"] == "Job")
    assert not any(e["name"].startswith("ORGANIZATION_IDENTITY_") for e in migration["spec"]["template"]["spec"]["containers"][0].get("env", []))


def test_enabled_staff_identity_requires_the_verified_onboarding_audience():
    import subprocess
    from test_helivanta_clinical_consent import ROOT
    result = subprocess.run(["helm", "template", "helivanta-api", str(ROOT / "charts/apps/helivanta-api"), "--namespace", "helivanta", "--set", "organizationIdentity.enabled=true"], capture_output=True, text=True)
    assert result.returncode != 0
    assert "organizationIdentity.tokenProjectID is required" in result.stderr
