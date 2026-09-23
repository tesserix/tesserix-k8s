"""Both sides of the storefront trust boundary must name the same env var.

marketplace-api gates every /api/v1/storefront/stores/* route on an
X-Storefront-Key header, and reads the expected value from
MARKETPLACE_STOREFRONT_KEY. When that variable is unset the middleware
NO-OPS — it serves 200 to a request with no key and to a request with a
wrong one.

The storefront chart used to inject the same secret under the name
STOREFRONT_KEY. Everything downstream of that looked correct: the
ExternalSecret synced, the pod carried the value, the values.yaml comment
said the engine validated requests with it, and the Next.js app opposite
faithfully sent the header on every call. The one thing that did not
happen was the server reading it.

So the invariant is not "a secret is mounted" — that was always true. It
is that the env NAME on both deployments matches what the binary reads.
"""

from pathlib import Path


ROOT = Path(__file__).parents[1]

# The name pkg/config declares:
#   StorefrontKey string `envconfig:"MARKETPLACE_STOREFRONT_KEY" default:""`
ENV_NAME = "MARKETPLACE_STOREFRONT_KEY"

# The key INSIDE the Kubernetes Secret, which is a separate thing from the
# env name and is legitimately still STOREFRONT_KEY on both charts.
SECRET_KEY = "STOREFRONT_KEY"

SERVER = ROOT / "charts/apps/mark8ly-marketplace-api-storefront"
CLIENT = ROOT / "charts/apps/mark8ly-storefront"


def _deployment(chart: Path) -> str:
    return (chart / "templates/deployment.yaml").read_text()


def test_server_reads_the_env_var_its_binary_actually_looks_up() -> None:
    rendered = _deployment(SERVER)

    assert f"- name: {ENV_NAME}" in rendered, (
        f"{SERVER.name} must inject {ENV_NAME}; any other name leaves "
        "cfg.StorefrontKey empty and RequireStorefrontKey a no-op"
    )
    # The bare name must not come back under a different env var. Guard the
    # exact regression rather than the general shape: a line declaring
    # `- name: STOREFRONT_KEY` is the bug, while `key: STOREFRONT_KEY` under
    # secretKeyRef is correct and must keep working.
    assert f"- name: {SECRET_KEY}\n" not in rendered


def test_client_and_server_agree_on_the_name_and_the_secret() -> None:
    server, client = _deployment(SERVER), _deployment(CLIENT)

    for chart_name, rendered in (("server", server), ("client", client)):
        assert f"- name: {ENV_NAME}" in rendered, chart_name

    # Same Secret on both sides: the header the app sends is only accepted
    # if the server compares it against the identical value.
    for chart in (SERVER, CLIENT):
        values = (chart / "values.yaml").read_text()
        assert "secretName: mark8ly-marketplace-api-storefront-key" in values
        assert f"secretKey: {SECRET_KEY}" in values
