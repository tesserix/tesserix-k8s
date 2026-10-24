from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/thirdparty/openpanel"


def test_clickhouse_bounds_cpu_and_stops_persisting_its_own_text_logs():
    rendered = subprocess.check_output(
        [
            "helm",
            "template",
            "openpanel",
            str(CHART),
            "-f",
            str(CHART / "values.yaml"),
            "-f",
            str(CHART / "values-prod.yaml"),
        ],
        text=True,
    )
    docs = [doc for doc in yaml.safe_load_all(rendered) if doc]
    config = next(
        doc
        for doc in docs
        if doc["kind"] == "ConfigMap"
        and doc["metadata"]["name"] == "openpanel-clickhouse-config"
    )
    logs = ET.fromstring(config["data"]["system-logs.xml"])
    assert logs.find("text_log").attrib.get("remove") == "1"
    assert logs.find("query_log/ttl").text == "event_date + INTERVAL 7 DAY DELETE"
    deployment = next(
        doc
        for doc in docs
        if doc["kind"] == "Deployment"
        and doc["metadata"]["name"] == "openpanel-clickhouse"
    )
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert container["resources"]["requests"]["cpu"] == "250m"
    assert str(container["resources"]["limits"]["cpu"]) == "2"
    assert container["resources"]["limits"]["memory"] == "4Gi"
    claim = next(
        doc
        for doc in docs
        if doc["kind"] == "PersistentVolumeClaim"
        and doc["metadata"]["name"] == "openpanel-clickhouse"
    )
    assert claim["spec"]["resources"]["requests"]["storage"] == "120Gi"
