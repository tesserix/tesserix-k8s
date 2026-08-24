#!/usr/bin/env python3

import argparse
import json
import pathlib
import subprocess
import sys

import yaml


ROOT = pathlib.Path(__file__).parents[1]
OUTPUT = ROOT / "charts/apps/agentgateway-route-sync/files/platform-resources.json"
CHARTS = (
    "charts/apps/devai-ai-gateway",
    "charts/apps/kora-ai-gateway",
    "charts/apps/agentgateway-route-sync",
)
EXPECTED = (
    ("AgentgatewayBackend", "ai-zitadel-jwks"),
    ("AgentgatewayBackend", "devai-anthropic"),
    ("AgentgatewayBackend", "devai-gemini"),
    ("AgentgatewayBackend", "devai-groq"),
    ("AgentgatewayBackend", "devai-nemoclaw"),
    ("AgentgatewayBackend", "devai-openai"),
    ("AgentgatewayBackend", "devai-openrouter"),
    ("AgentgatewayBackend", "devai-vertex"),
    ("AgentgatewayBackend", "kora-conversation-providers"),
    ("AgentgatewayBackend", "kora-embedding-providers"),
    ("AgentgatewayBackend", "kora-firebase-jwks"),
    ("AgentgatewayBackend", "kora-structured-providers"),
    ("AgentgatewayBackend", "mcp-zitadel-jwks"),
    ("HTTPRoute", "devai-ai"),
    ("HTTPRoute", "kora-ai"),
    ("AgentgatewayPolicy", "ai-public-oauth"),
    ("AgentgatewayPolicy", "ai-public-observability"),
    ("AgentgatewayPolicy", "devai-ai-observability"),
    ("AgentgatewayPolicy", "devai-ai-routes"),
    ("AgentgatewayPolicy", "devai-ai-traffic"),
    ("AgentgatewayPolicy", "kora-a2a-user-auth"),
    ("AgentgatewayPolicy", "kora-ai-guardrails"),
    ("AgentgatewayPolicy", "kora-ai-observability"),
    ("AgentgatewayPolicy", "kora-ai-traffic"),
    ("AgentgatewayPolicy", "kora-user-auth"),
    ("AgentgatewayPolicy", "mcp-public-oauth"),
    ("AgentgatewayPolicy", "mcp-public-observability"),
)


def render_chart(chart: str) -> list[dict]:
    result = subprocess.run(
        [
            "helm",
            "template",
            "registry-platform-seed",
            str(ROOT / chart),
            "--namespace",
            "agentgateway-system",
            "--set",
            "registryOwnership.enabled=false",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def generate() -> str:
    resources = {}
    for chart in CHARTS:
        for document in render_chart(chart):
            metadata = document.get("metadata", {})
            key = (document.get("kind"), metadata.get("name"))
            if key not in EXPECTED:
                continue
            if key in resources:
                raise ValueError(f"duplicate platform resource: {key[0]}/{key[1]}")
            resources[key] = {
                "apiVersion": document["apiVersion"],
                "kind": document["kind"],
                "metadata": {
                    "name": metadata["name"],
                    "namespace": "agentgateway-system",
                },
                "spec": document["spec"],
            }

    missing = set(EXPECTED) - resources.keys()
    if missing:
        names = ", ".join(f"{kind}/{name}" for kind, name in sorted(missing))
        raise ValueError(f"missing platform resources: {names}")

    payload = {
        "apiVersion": "v1",
        "kind": "List",
        "items": [resources[key] for key in EXPECTED],
    }
    return json.dumps(payload, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    generated = generate()

    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != generated:
            print(f"{OUTPUT.relative_to(ROOT)} is out of date", file=sys.stderr)
            return 1
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(generated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
