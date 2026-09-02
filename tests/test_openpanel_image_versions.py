from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "charts/thirdparty/openpanel"


def version_tuple(version):
    return tuple(int(part) for part in version.split("-", 1)[0].split("."))


def test_openpanel_images_include_the_management_api_and_stay_aligned():
    chart = yaml.safe_load((CHART / "Chart.yaml").read_text())
    values = yaml.safe_load((CHART / "values.yaml").read_text())
    image_tags = {
        component: values[component]["image"]["tag"]
        for component in ("api", "dashboard", "worker")
    }

    assert set(image_tags.values()) == {chart["appVersion"]}
    assert version_tuple(chart["appVersion"]) >= (2, 1, 0)
