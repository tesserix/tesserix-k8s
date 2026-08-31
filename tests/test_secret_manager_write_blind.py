"""The secret-service console must be able to write a secret and never read one.

That guarantee is not enforced by any code we own. It is enforced by the absence
of a single string — `secretmanager.versions.access` — from one custom IAM role.
Every other `versions.*` verb manipulates a version without returning its
payload; `access` is the only one that hands back the bytes. Add it and the
console silently gains the ability to read every secret in the project, while
looking and behaving exactly as it does now.

So these tests pin the absence, not the presence. See tesserix-home#465.
"""

import re
from pathlib import Path


STACK = Path("terraform-new/stacks/06-workload-identity/main.tf")
TFVARS = Path("terraform-new/environments/prod/terraform.tfvars")
CHART_VALUES = Path("charts/apps/secret-service/values.yaml")
CHART_DEPLOYMENT = Path("charts/apps/secret-service/templates/deployment-api.yaml")

ROLE_ID = "secretManagerWriteBlind"
QUALIFIED_ROLE = f"projects/tesseracthub-480811/roles/{ROLE_ID}"

# Exactly the permissions the console needs to manage a secret's lifecycle.
# Deliberately spelled out rather than derived: the point of the test is to make
# any change to this list show up as a diff in the test as well as the stack.
EXPECTED_PERMISSIONS = {
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.update",
    "secretmanager.versions.add",
    "secretmanager.versions.destroy",
    "secretmanager.versions.disable",
    "secretmanager.versions.enable",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
}

# Permissions that return a secret payload. `versions.access` is the only one
# Secret Manager defines today; the wildcards would grant it transitively.
PAYLOAD_READING_PERMISSIONS = {
    "secretmanager.versions.access",
    "secretmanager.*",
    "*",
}


def _write_blind_permissions() -> set[str]:
    """The `permissions` list of the write-blind custom role, as declared."""
    source = STACK.read_text()

    block = re.search(
        r'resource\s+"google_project_iam_custom_role"\s+"secret_manager_write_blind"\s*\{(.*?)\n\}',
        source,
        re.DOTALL,
    )
    assert block, f"write-blind custom role is no longer declared in {STACK}"

    permissions = re.search(r"permissions\s*=\s*\[(.*?)\]", block.group(1), re.DOTALL)
    assert permissions, f"write-blind role in {STACK} declares no permissions list"

    return set(re.findall(r'"([^"]+)"', permissions.group(1)))


def test_write_blind_role_cannot_read_a_payload() -> None:
    """The whole guarantee, in one assertion."""
    granted = _write_blind_permissions()

    leaks = granted & PAYLOAD_READING_PERMISSIONS
    assert not leaks, (
        f"{ROLE_ID} grants {sorted(leaks)}, which returns secret payloads. "
        "The secret-service console would be able to read back every secret it "
        "can see. If this is intended, the write-blind guarantee in "
        "tesserix-home#274 no longer holds and must be withdrawn, not weakened."
    )


def test_write_blind_role_grants_exactly_the_expected_permissions() -> None:
    """Catch widening that is not `versions.access` itself.

    A future Secret Manager permission could return payloads under another name,
    so the safe posture is an allowlist: anything new has to be added here
    deliberately, by someone who has thought about whether it reads.
    """
    granted = _write_blind_permissions()

    assert granted == EXPECTED_PERMISSIONS, (
        f"unexpected: {sorted(granted - EXPECTED_PERMISSIONS)}, "
        f"missing: {sorted(EXPECTED_PERMISSIONS - granted)}"
    )


def test_write_blind_role_only_covers_secret_manager() -> None:
    granted = _write_blind_permissions()

    foreign = {p for p in granted if not p.startswith("secretmanager.")}
    assert not foreign, f"{ROLE_ID} grants non-Secret-Manager permissions: {sorted(foreign)}"


def _secret_service_account_block() -> str:
    """The `secret-service` entry of `service_accounts` in prod tfvars."""
    source = TFVARS.read_text()

    block = re.search(
        r'\{[^{}]*name\s*=\s*"secret-service"(?:[^{}]|\{[^{}]*\})*?\n  \}',
        source,
        re.DOTALL,
    )
    assert block, f"no service_accounts entry named secret-service in {TFVARS}"
    return block.group(0)


def test_console_service_account_holds_only_the_write_blind_role() -> None:
    """A role that excludes `versions.access` protects nothing if a second role
    granting it is bound alongside. The binding is additive, so the count matters
    as much as the contents."""
    block = _secret_service_account_block()

    project_roles = re.search(r"project_roles\s*=\s*\[(.*?)\]", block, re.DOTALL)
    assert project_roles, "secret-service entry declares no project_roles"

    roles = re.findall(r'"([^"]+)"', project_roles.group(1))
    assert roles == [QUALIFIED_ROLE], (
        f"secret-service holds {roles}; it must hold exactly [{QUALIFIED_ROLE}]. "
        "An additional role can restore payload read access without touching "
        "the write-blind role at all."
    )


def test_console_service_account_grants_no_per_secret_access() -> None:
    """`secret_bindings` would grant per-secret roles that bypass the project-level
    write-blind role entirely."""
    block = _secret_service_account_block()

    for field in ("bucket_bindings", "secret_bindings"):
        empty = re.search(rf"{field}\s*=\s*\[\s*\]", block)
        assert empty, (
            f"secret-service declares a non-empty {field}; a per-secret grant can "
            "carry secretAccessor and defeat the write-blind role."
        )


def test_workload_identity_binding_matches_the_deployed_chart() -> None:
    """The role reaches the console only through this (namespace, KSA) pair. If the
    chart is renamed on either side the binding silently stops applying, and the
    pod falls back to no Google credentials — or, worse, someone re-points it."""
    block = _secret_service_account_block()

    binding = re.search(
        r'namespace\s*=\s*"([^"]+)"\s*,\s*kubernetes_service_account\s*=\s*"([^"]+)"',
        block,
    )
    assert binding, "secret-service declares no workload_identity_bindings pair"
    namespace, ksa = binding.groups()

    chart_namespace = re.search(r"^namespace:\s*(\S+)", CHART_VALUES.read_text(), re.MULTILINE)
    assert chart_namespace, f"no top-level namespace in {CHART_VALUES}"

    chart_ksa = re.search(
        r"^\s*serviceAccountName:\s*(\S+)", CHART_DEPLOYMENT.read_text(), re.MULTILINE
    )
    assert chart_ksa, f"no serviceAccountName in {CHART_DEPLOYMENT}"

    assert (namespace, ksa) == (chart_namespace.group(1), chart_ksa.group(1)), (
        f"terraform binds ({namespace}, {ksa}) but the chart deploys "
        f"({chart_namespace.group(1)}, {chart_ksa.group(1)})"
    )
