from pathlib import Path

import yaml


def test_trip_manager_has_time_to_return_and_is_not_retried():
    manifest = Path(__file__).parents[1] / "manifests/roamie-istio/virtualservice.yaml"
    routes = yaml.safe_load(manifest.read_text())["spec"]["http"]
    route = next(
        route
        for route in routes
        if any(
            match.get("uri", {}).get("exact") == "/v1/trip-manager"
            for match in route.get("match", [])
        )
    )
    assert 85 < int(route["timeout"].removesuffix("s")) <= 95
    assert route["retries"]["attempts"] == 0
    assert (
        route["route"][0]["destination"]["host"]
        == "roamie-api.roamie.svc.cluster.local"
    )
