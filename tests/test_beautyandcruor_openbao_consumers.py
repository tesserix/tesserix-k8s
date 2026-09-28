from test_homechef_openbao_access import render, resource


def test_admin_and_enquiry_read_only_openbao():
    docs = render("charts/apps/beautyandcruor")
    admin = resource(docs, "ExternalSecret", "beautyandcruor-admin")["spec"]
    assert admin["secretStoreRef"] == {
        "kind": "SecretStore",
        "name": "openbao-beautyandcruor-production",
    }
    assert {d["secretKey"] for d in admin["data"]} == {
        "password-hash",
        "session-key",
        "github-token",
    }
    for d in admin["data"]:
        assert d["remoteRef"] == {
            "key": "beautyandcruor/app/beautyandcruor-admin-" + d["secretKey"],
            "property": "value",
        }
    enquiry = resource(docs, "ExternalSecret", "beautyandcruor-enquiry")["spec"]
    assert enquiry["secretStoreRef"] == {
        "kind": "SecretStore",
        "name": "openbao-fe3dr-appdeps",
    }
    assert enquiry["data"][0]["remoteRef"] == {
        "key": "homechef/homechef-api/fe3dr-resend-api-key",
        "property": "value",
    }
