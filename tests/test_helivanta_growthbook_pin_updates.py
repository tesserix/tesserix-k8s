from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_kargo_scalar_updates_cannot_truncate_inline_parameter_mappings():
    source = (ROOT / "argocd/prod/apps/helivanta/helivanta-growthbook.yaml").read_text()
    document = yaml.compose(source)
    def field(node, name):
        return next(value for key, value in node.value if key.value == name)
    parameters = field(field(field(field(document, "spec"), "source"), "helm"), "parameters")
    assert len(parameters.value) == 2
    for parameter in parameters.value:
        assert not parameter.flow_style, "Kargo yaml-update replaces scalar lines; use block mappings"
        assert field(parameter, "forceString").value == "true"
