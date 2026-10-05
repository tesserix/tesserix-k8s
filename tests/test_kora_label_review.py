import json
import pathlib

from test_kora_ai_gateway_manifests import render_chart, resource


def test_label_review_has_independent_stronger_route_with_user_authentication():
    docs = render_chart("charts/apps/kora-ai-gateway", "kora-ai-gateway", "agentgateway-system")
    route = resource(docs, "HTTPRoute", "kora-ai")
    rule = next(r for r in route["spec"]["rules"] if r["name"] == "label-review")
    assert rule["matches"][0]["headers"] == [{"name": "x-kora-ai-capability", "type": "Exact", "value": "read_label_review"}]
    assert rule["backendRefs"][0]["name"] == "kora-label-review-providers"
    assert "X-Kora-End-User-Token" in rule["filters"][0]["requestHeaderModifier"]["remove"]
    backend = resource(docs, "AgentgatewayBackend", "kora-label-review-providers")
    groups = backend["spec"]["ai"]["groups"]
    assert len(groups) == 1
    assert groups[0]["providers"][0]["anthropic"]["model"] == "claude-sonnet-5-5"
    auth = resource(docs, "AgentgatewayPolicy", "kora-user-auth")["spec"]
    assert any(t.get("sectionName") == "label-review" for t in auth["targetRefs"])
    assert auth["traffic"]["jwtAuthentication"]["mode"] == "Strict"
    bundle = json.loads((pathlib.Path(__file__).parents[1] / "charts/apps/agentgateway-route-sync/files/platform-resources.json").read_text())
    resource(bundle["items"], "AgentgatewayBackend", "kora-label-review-providers")

    for name in ("kora-structured-providers", "kora-conversation-providers"):
        groups = resource(docs, "AgentgatewayBackend", name)["spec"]["ai"]["groups"]
        assert groups[1]["providers"][0]["anthropic"]["model"] == "claude-sonnet-4-5"
