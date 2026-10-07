"""The two marketplace-api charts must not drift apart by accident.

`mark8ly-marketplace-api-admin` and `mark8ly-marketplace-api-storefront`
deploy the SAME binary. They differ only in which routes they serve and a
handful of deliberately app-specific settings. Every other environment
variable has to be present in both, because the binary reads the same
config struct either way.

That has now failed three times, each time costing a feature that looked
correct in review and in the code:

  - MARKETPLACE_GCS_SIGNER_SA_EMAIL was added to the admin chart only
    (mark8ly#1293). Buyer artwork uploads could not be signed.
  - MARKETPLACE_PRIVATE_GCS_BUCKET, likewise.
  - MARKETPLACE_MEDIA_PUBLIC_BASE_URL, likewise (mark8ly#1322). The 2D
    mockup composite silently did not render for any buyer, for days.

Each omission degrades to plausible behaviour rather than an error. The
mockup mapper, correctly, drops the mockup when the base URL is empty —
a relative path would 404 against the storefront's own origin — so
"misconfigured" and "no mockup configured" look identical from outside.
Nothing crashes, nothing logs, and a reviewer reading the Go code sees a
feature that works.

So the property worth testing is not whether either chart is internally
valid. Both always were. It is whether a variable added to one was added
to the other, with the exceptions written down and justified rather than
inferred.
"""

import re
from pathlib import Path


ROOT = Path(__file__).parents[1]
ADMIN = ROOT / "charts/apps/mark8ly-marketplace-api-admin/templates/deployment.yaml"
STOREFRONT = (
    ROOT / "charts/apps/mark8ly-marketplace-api-storefront/templates/deployment.yaml"
)

# Variables allowed to exist in only ONE chart, and why. Anything not
# listed here must appear in both.
#
# Add to this map only with a reason that survives the question "what
# breaks in the other app if it is missing?" — the three incidents above
# all had an answer to that and were added to one chart anyway.
INTENTIONAL = {
    "MARKETPLACE_GCS_BUCKET": (
        "admin",
        "The PUBLIC media bucket, written to when a merchant uploads product "
        "artwork. The storefront only ever reads media, and reads it through "
        "MARKETPLACE_MEDIA_PUBLIC_BASE_URL rather than the bucket name.",
    ),
    "MARKETPLACE_MEDIA_CACHE_CONTROL": (
        "admin",
        "Cache-Control stamped onto objects at UPLOAD time. Only the admin "
        "writes objects.",
    ),
    "MARKETPLACE_PLATFORM_ADMIN_SECRET": (
        "admin",
        "Authenticates platform-api -> marketplace-api admin calls. The "
        "storefront serves no admin routes, and giving the anonymous-facing "
        "deployment this secret would widen its blast radius for nothing.",
    ),
    "MARKETPLACE_STOREFRONT_KEY": (
        "storefront",
        "Shared secret for the Next storefront's server-side calls. The "
        "admin deployment serves no storefront routes.",
    ),
}

ENV_NAME = re.compile(r"^\s*-?\s*name:\s*(MARKETPLACE_[A-Z0-9_]+)\s*$", re.MULTILINE)


def _env_names(path: Path) -> set[str]:
    """Env var names in a chart's deployment template.

    Read as text, not YAML: these are Go templates and will not parse.
    The names themselves are plain literals, which is all this needs.
    """
    assert path.exists(), f"missing chart template: {path}"
    return set(ENV_NAME.findall(path.read_text()))


def test_no_unlisted_drift_between_the_two_marketplace_api_charts():
    admin = _env_names(ADMIN)
    storefront = _env_names(STOREFRONT)

    # Sanity: a regex that silently matched nothing would make this test
    # pass forever while checking nothing, which is the exact failure
    # mode this file exists to prevent.
    assert len(admin) > 5, f"only found {len(admin)} env vars in the admin chart"
    assert len(storefront) > 5, (
        f"only found {len(storefront)} env vars in the storefront chart"
    )

    unlisted = []
    for name in sorted(admin - storefront):
        if INTENTIONAL.get(name, (None,))[0] != "admin":
            unlisted.append(f"  {name}: in admin, MISSING from storefront")
    for name in sorted(storefront - admin):
        if INTENTIONAL.get(name, (None,))[0] != "storefront":
            unlisted.append(f"  {name}: in storefront, MISSING from admin")

    assert not unlisted, (
        "marketplace-api chart drift.\n\n"
        + "\n".join(unlisted)
        + "\n\nBoth deployments run the same binary and read the same config "
        "struct. If this variable really belongs to one app only, add it to "
        "INTENTIONAL in this file with the reason. Otherwise add it to the "
        "other chart — a missing one does not crash, it silently disables a "
        "feature."
    )


def test_intentional_exceptions_are_still_exceptions():
    """A stale allowlist is how the next omission gets waved through.

    If a variable listed as app-specific has since been added to both
    charts, the entry no longer describes reality and must go — otherwise
    it sits there granting permission for a difference that no longer
    exists.
    """
    admin = _env_names(ADMIN)
    storefront = _env_names(STOREFRONT)

    stale = []
    for name, (owner, _reason) in sorted(INTENTIONAL.items()):
        present_in_both = name in admin and name in storefront
        in_neither = name not in admin and name not in storefront
        if present_in_both:
            stale.append(f"  {name}: listed as {owner}-only but present in BOTH")
        elif in_neither:
            stale.append(f"  {name}: listed as {owner}-only but present in NEITHER")
        elif owner == "admin" and name not in admin:
            stale.append(f"  {name}: listed as admin-only but only in storefront")
        elif owner == "storefront" and name not in storefront:
            stale.append(f"  {name}: listed as storefront-only but only in admin")

    assert not stale, (
        "INTENTIONAL no longer matches the charts.\n\n"
        + "\n".join(stale)
        + "\n\nRemove the entry if the difference is gone, or correct which "
        "chart owns it."
    )
