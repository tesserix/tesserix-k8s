#!/usr/bin/env python3
"""
Audit GCE persistent disks, k8s PVs, and PVCs for orphans, broken refs, and
disassociated state. Classifies each disk into a category and decides whether
it is safe to delete.

Categories
----------
ATTACHED              Disk mounted on a node — leave alone.
NORMAL                Disk -> PV -> PVC -> Pod chain intact.
CNPG_MEMBER           PVC bound to an active CNPG cluster member (in scope of
                      cluster.spec.instances). Will be remounted on next
                      pod restart — DO NOT DELETE.
CNPG_OUT_OF_SCOPE     PVC matches a CNPG cluster name but its ordinal is
                      higher than cluster.spec.instances. Replica was scaled
                      down; humans should confirm before delete.
STS_MEMBER            PVC bound to an active StatefulSet member.
STS_OUT_OF_SCOPE      PVC matches a StatefulSet pattern but ordinal >= replicas.
PVC_NO_OWNER          PVC exists, has no pod and no recognised controller
                      pattern. Could be intentional manual data; flag for
                      review only.
RELEASED_PV           PV.status=Released (PVC gone, reclaim=Retain held the PV).
                      Safe to delete after AGE_THRESHOLD days.
ZOMBIE_DISK           GCE disk with no matching k8s PV at all. Either the PV
                      was deleted manually or the cluster was rebuilt.
                      Safe to delete after AGE_THRESHOLD days.

The script outputs a Markdown report on stdout and can optionally execute
"safe" deletes (ZOMBIE_DISK + RELEASED_PV older than --age-days) when run
with --apply.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any

NOW = dt.datetime.now(dt.timezone.utc)
PD_NAME_RE = re.compile(r"^pvc-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")
CNPG_INSTANCE_RE = re.compile(r"^(?P<cluster>.+?)-(?P<ordinal>\d+)(?P<wal>-wal)?$")


# ---------------------------------------------------------------------------
# subprocess helpers
# ---------------------------------------------------------------------------

def run(cmd: list[str], check: bool = True) -> str:
    res = subprocess.run(cmd, capture_output=True, text=True)
    if check and res.returncode != 0:
        sys.stderr.write(f"command failed: {' '.join(cmd)}\n{res.stderr}\n")
        sys.exit(2)
    return res.stdout


def kubectl_json(args: list[str]) -> dict[str, Any]:
    out = run(["kubectl"] + args + ["-o", "json"])
    return json.loads(out) if out.strip() else {"items": []}


def gcloud_json(args: list[str]) -> Any:
    out = run(["gcloud"] + args + ["--format=json"])
    return json.loads(out) if out.strip() else []


def parse_ts(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def days_since(t: dt.datetime | None) -> float | None:
    if t is None:
        return None
    return (NOW - t).total_seconds() / 86400.0


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

@dataclass
class Inventory:
    disks: list[dict[str, Any]] = field(default_factory=list)            # gcloud
    pvs: dict[str, dict[str, Any]] = field(default_factory=dict)         # by pv name
    pvcs: dict[tuple[str, str], dict[str, Any]] = field(default_factory=dict)  # (ns, name)
    pods_by_pvc: dict[tuple[str, str], list[dict[str, Any]]] = field(default_factory=lambda: defaultdict(list))
    cnpg: dict[tuple[str, str], dict[str, Any]] = field(default_factory=dict)  # by (ns, cluster)
    sts: dict[tuple[str, str], dict[str, Any]] = field(default_factory=dict)   # by (ns, sts)
    pv_by_disk: dict[str, str] = field(default_factory=dict)              # disk name -> pv name


def build_inventory(project: str) -> Inventory:
    inv = Inventory()

    inv.disks = gcloud_json(["compute", "disks", "list", "--project", project])

    pvs = kubectl_json(["get", "pv"])
    for pv in pvs["items"]:
        inv.pvs[pv["metadata"]["name"]] = pv
        # GCE PD: spec.csi.volumeHandle is "projects/PROJECT/zones/ZONE/disks/NAME"
        # or for older in-tree, spec.gcePersistentDisk.pdName
        disk_name = ""
        csi = pv.get("spec", {}).get("csi", {})
        gcepd = pv.get("spec", {}).get("gcePersistentDisk", {})
        if csi:
            handle = csi.get("volumeHandle", "")
            disk_name = handle.split("/")[-1] if handle else ""
        elif gcepd:
            disk_name = gcepd.get("pdName", "")
        if disk_name:
            inv.pv_by_disk[disk_name] = pv["metadata"]["name"]

    pvcs = kubectl_json(["get", "pvc", "-A"])
    for pvc in pvcs["items"]:
        m = pvc["metadata"]
        inv.pvcs[(m["namespace"], m["name"])] = pvc

    pods = kubectl_json(["get", "pods", "-A"])
    for pod in pods["items"]:
        ns = pod["metadata"]["namespace"]
        for v in pod.get("spec", {}).get("volumes", []) or []:
            pvc_ref = v.get("persistentVolumeClaim", {}) or {}
            cn = pvc_ref.get("claimName")
            if cn:
                inv.pods_by_pvc[(ns, cn)].append(pod)

    # CNPG clusters (CRD may not exist if operator isn't installed)
    try:
        cnpg = kubectl_json(["get", "cluster.postgresql.cnpg.io", "-A"])
        for c in cnpg.get("items", []):
            m = c["metadata"]
            inv.cnpg[(m["namespace"], m["name"])] = c
    except SystemExit:
        pass  # CRD missing, ignore

    sts = kubectl_json(["get", "sts", "-A"])
    for s in sts["items"]:
        m = s["metadata"]
        inv.sts[(m["namespace"], m["name"])] = s

    return inv


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

@dataclass
class Finding:
    category: str
    disk_name: str
    disk_size_gb: int
    disk_zone: str
    disk_attached: bool
    disk_last_detach_days: float | None
    pv_name: str | None
    pv_phase: str | None
    pvc_namespace: str | None
    pvc_name: str | None
    detail: str = ""
    safe_to_delete: bool = False


def cnpg_match(pvc_name: str, ns: str, inv: Inventory) -> tuple[dict[str, Any] | None, int | None, bool]:
    """Return (cluster_obj, ordinal, is_wal) if pvc_name matches a CNPG cluster
    in this namespace; otherwise (None, None, False)."""
    m = CNPG_INSTANCE_RE.match(pvc_name)
    if not m:
        return None, None, False
    cluster_name = m.group("cluster")
    ordinal = int(m.group("ordinal"))
    is_wal = bool(m.group("wal"))
    cluster = inv.cnpg.get((ns, cluster_name))
    return (cluster, ordinal, is_wal) if cluster else (None, None, False)


def sts_match(pvc_name: str, ns: str, inv: Inventory) -> tuple[dict[str, Any] | None, int | None, str]:
    """Match StatefulSet PVC pattern:
        <volumeClaimTemplate.name>-<stsName>-<ordinal>
    """
    for (sts_ns, sts_name), s in inv.sts.items():
        if sts_ns != ns:
            continue
        for tpl in s.get("spec", {}).get("volumeClaimTemplates", []) or []:
            tpl_name = tpl.get("metadata", {}).get("name", "")
            if not tpl_name:
                continue
            prefix = f"{tpl_name}-{sts_name}-"
            if pvc_name.startswith(prefix):
                tail = pvc_name[len(prefix):]
                if tail.isdigit():
                    return s, int(tail), tpl_name
    return None, None, ""


def classify(inv: Inventory, age_days: int) -> list[Finding]:
    findings: list[Finding] = []
    seen_pvs: set[str] = set()

    # 1) Iterate every GCE disk
    for d in inv.disks:
        name = d.get("name", "")
        # Skip GKE node boot disks (they aren't pvc-* named)
        if not PD_NAME_RE.match(name):
            continue

        size = int(d.get("sizeGb", 0))
        zone = d.get("zone", "").rsplit("/", 1)[-1]
        users = d.get("users") or []
        attached = bool(users)
        last_detach = parse_ts(d.get("lastDetachTimestamp"))
        detach_days = days_since(last_detach)

        pv_name = inv.pv_by_disk.get(name)
        pv = inv.pvs.get(pv_name) if pv_name else None
        if pv:
            seen_pvs.add(pv_name)

        if pv is None:
            # ZOMBIE: disk exists, no PV references it
            findings.append(Finding(
                category="ZOMBIE_DISK",
                disk_name=name, disk_size_gb=size, disk_zone=zone,
                disk_attached=attached, disk_last_detach_days=detach_days,
                pv_name=None, pv_phase=None,
                pvc_namespace=None, pvc_name=None,
                detail=f"GCE disk has no matching PV. lastDetach={detach_days:.1f}d ago." if detach_days else "GCE disk has no matching PV. Never detached.",
                safe_to_delete=(not attached) and (detach_days is None or detach_days >= age_days),
            ))
            continue

        phase = pv.get("status", {}).get("phase", "")
        claim_ref = pv.get("spec", {}).get("claimRef", {}) or {}
        pvc_ns = claim_ref.get("namespace")
        pvc_name = claim_ref.get("name")

        if phase == "Released" or not pvc_ns:
            findings.append(Finding(
                category="RELEASED_PV",
                disk_name=name, disk_size_gb=size, disk_zone=zone,
                disk_attached=attached, disk_last_detach_days=detach_days,
                pv_name=pv_name, pv_phase=phase,
                pvc_namespace=pvc_ns, pvc_name=pvc_name,
                detail=f"PV phase={phase} reclaim={pv.get('spec',{}).get('persistentVolumeReclaimPolicy')}.",
                safe_to_delete=(not attached) and (detach_days is None or detach_days >= age_days),
            ))
            continue

        pvc = inv.pvcs.get((pvc_ns, pvc_name))
        if pvc is None:
            findings.append(Finding(
                category="RELEASED_PV",
                disk_name=name, disk_size_gb=size, disk_zone=zone,
                disk_attached=attached, disk_last_detach_days=detach_days,
                pv_name=pv_name, pv_phase=phase,
                pvc_namespace=pvc_ns, pvc_name=pvc_name,
                detail=f"PV claimRef {pvc_ns}/{pvc_name} but PVC missing — Released-equivalent.",
                safe_to_delete=(not attached) and (detach_days is None or detach_days >= age_days),
            ))
            continue

        # PVC exists. Now classify by who it belongs to.
        pods = inv.pods_by_pvc.get((pvc_ns, pvc_name), [])
        running = [p for p in pods if p.get("status", {}).get("phase") in ("Running", "Pending")]

        if running:
            findings.append(Finding(
                category="ATTACHED" if attached else "NORMAL",
                disk_name=name, disk_size_gb=size, disk_zone=zone,
                disk_attached=attached, disk_last_detach_days=detach_days,
                pv_name=pv_name, pv_phase=phase,
                pvc_namespace=pvc_ns, pvc_name=pvc_name,
                detail=f"Pods using PVC: {', '.join(p['metadata']['name'] for p in running[:3])}",
                safe_to_delete=False,
            ))
            continue

        # No running pod; check CNPG / STS membership.
        cluster, ordinal, is_wal = cnpg_match(pvc_name, pvc_ns, inv)
        if cluster is not None:
            instances = int(cluster.get("spec", {}).get("instances", 0))
            cluster_name = cluster["metadata"]["name"]
            in_scope = ordinal is not None and ordinal <= instances
            findings.append(Finding(
                category="CNPG_MEMBER" if in_scope else "CNPG_OUT_OF_SCOPE",
                disk_name=name, disk_size_gb=size, disk_zone=zone,
                disk_attached=attached, disk_last_detach_days=detach_days,
                pv_name=pv_name, pv_phase=phase,
                pvc_namespace=pvc_ns, pvc_name=pvc_name,
                detail=(f"CNPG cluster {pvc_ns}/{cluster_name} instances={instances}, "
                        f"ordinal={ordinal}, wal={is_wal}. "
                        f"{'In scope — pod likely restarting/migrating.' if in_scope else 'Replica was scaled down; review.'}"),
                safe_to_delete=False,  # never auto-delete CNPG data
            ))
            continue

        s, sts_ord, tpl = sts_match(pvc_name, pvc_ns, inv)
        if s is not None:
            replicas = int(s.get("spec", {}).get("replicas", 0))
            sts_name = s["metadata"]["name"]
            in_scope = sts_ord is not None and sts_ord < replicas
            findings.append(Finding(
                category="STS_MEMBER" if in_scope else "STS_OUT_OF_SCOPE",
                disk_name=name, disk_size_gb=size, disk_zone=zone,
                disk_attached=attached, disk_last_detach_days=detach_days,
                pv_name=pv_name, pv_phase=phase,
                pvc_namespace=pvc_ns, pvc_name=pvc_name,
                detail=(f"StatefulSet {pvc_ns}/{sts_name} replicas={replicas}, "
                        f"template={tpl}, ordinal={sts_ord}. "
                        f"{'In scope — pod likely down briefly.' if in_scope else 'Scaled down; review.'}"),
                safe_to_delete=False,
            ))
            continue

        findings.append(Finding(
            category="PVC_NO_OWNER",
            disk_name=name, disk_size_gb=size, disk_zone=zone,
            disk_attached=attached, disk_last_detach_days=detach_days,
            pv_name=pv_name, pv_phase=phase,
            pvc_namespace=pvc_ns, pvc_name=pvc_name,
            detail="PVC bound but no pod, no STS, no CNPG cluster references it.",
            safe_to_delete=False,
        ))

    # 2) Now Released PVs whose disk is ALREADY gone (PV outlived the disk).
    for pv_name, pv in inv.pvs.items():
        if pv_name in seen_pvs:
            continue
        phase = pv.get("status", {}).get("phase", "")
        if phase != "Released":
            continue
        capacity = pv.get("spec", {}).get("capacity", {}).get("storage", "0")
        # crude size in GiB
        size = 0
        try:
            if capacity.endswith("Gi"):
                size = int(capacity[:-2])
            elif capacity.endswith("G"):
                size = int(capacity[:-1])
        except ValueError:
            pass
        findings.append(Finding(
            category="RELEASED_PV",
            disk_name="(no disk)", disk_size_gb=size, disk_zone="",
            disk_attached=False, disk_last_detach_days=None,
            pv_name=pv_name, pv_phase=phase,
            pvc_namespace=None, pvc_name=None,
            detail="PV is Released and underlying disk has already been deleted.",
            safe_to_delete=True,
        ))

    return findings


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

CATEGORY_ORDER = [
    "ZOMBIE_DISK",
    "RELEASED_PV",
    "PVC_NO_OWNER",
    "CNPG_OUT_OF_SCOPE",
    "STS_OUT_OF_SCOPE",
    "CNPG_MEMBER",
    "STS_MEMBER",
    "NORMAL",
    "ATTACHED",
]

CATEGORY_DESC = {
    "ZOMBIE_DISK":       "🟥 GCE disk with no matching PV — safe to delete after age threshold",
    "RELEASED_PV":       "🟧 PV is Released (PVC gone) — safe to delete after age threshold",
    "PVC_NO_OWNER":      "🟨 PVC exists but no pod/STS/CNPG owner — review manually",
    "CNPG_OUT_OF_SCOPE": "🟦 CNPG cluster member, ordinal beyond cluster.spec.instances — review",
    "STS_OUT_OF_SCOPE":  "🟦 StatefulSet member, ordinal beyond replicas — review",
    "CNPG_MEMBER":       "🟩 CNPG cluster member in scope — DO NOT DELETE",
    "STS_MEMBER":        "🟩 StatefulSet member in scope — DO NOT DELETE",
    "NORMAL":            "✅ Disk → PV → PVC → Pod chain intact",
    "ATTACHED":          "✅ Disk attached to a node",
}


def render_markdown(findings: list[Finding], age_days: int, applied: bool) -> str:
    by_cat: dict[str, list[Finding]] = defaultdict(list)
    for f in findings:
        by_cat[f.category].append(f)

    lines = []
    lines.append(f"# Orphan storage audit — {NOW.strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append("")
    lines.append(f"Threshold for auto-delete: **{age_days} days** since last detach.")
    if applied:
        lines.append("")
        lines.append("> **Apply mode was enabled.** Safe categories were deleted; see Action log below.")
    lines.append("")
    if not findings:
        lines.append("> ⚠️  Inventory was empty — script saw zero pvc-* disks. Verify the CI service")
        lines.append("> account has `roles/compute.storageAdmin` and that kubectl can list PV/PVC/Pods.")
        lines.append("")

    # Summary table
    lines.append("## Summary")
    lines.append("")
    lines.append("| Category | Count | Total GB | Description |")
    lines.append("|---|---:|---:|---|")
    for cat in CATEGORY_ORDER:
        items = by_cat.get(cat, [])
        total = sum(f.disk_size_gb for f in items)
        if items:
            lines.append(f"| `{cat}` | {len(items)} | {total} | {CATEGORY_DESC[cat]} |")
    lines.append("")

    # Per-category detail
    for cat in CATEGORY_ORDER:
        items = sorted(by_cat.get(cat, []), key=lambda f: -(f.disk_size_gb or 0))
        if not items:
            continue
        lines.append(f"## {cat}  ({len(items)} item(s))")
        lines.append("")
        lines.append(f"_{CATEGORY_DESC[cat]}_")
        lines.append("")
        lines.append("| Disk | Size GB | Zone | Detach age | PV | PVC | Detail |")
        lines.append("|---|---:|---|---|---|---|---|")
        for f in items:
            detach = f"{f.disk_last_detach_days:.1f}d" if f.disk_last_detach_days is not None else "-"
            pv = f.pv_name or "-"
            pvc = f"{f.pvc_namespace}/{f.pvc_name}" if f.pvc_namespace else "-"
            lines.append(f"| `{f.disk_name}` | {f.disk_size_gb} | {f.disk_zone or '-'} | {detach} | `{pv}` | `{pvc}` | {f.detail} |")
        lines.append("")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Apply (delete) — only the safest categories.
# ---------------------------------------------------------------------------

def _action_line(ok: bool, what: str, res: subprocess.CompletedProcess) -> str:
    # A bare FAIL is undiagnosable from the report (the 2026-08-29 run failed
    # every PV delete for a month of RBAC denials nobody saw) — keep the last
    # stderr line.
    if ok:
        return f"OK: {what}"
    reason = (res.stderr or "").strip().splitlines()
    return f"FAIL: {what} — {reason[-1] if reason else 'no stderr'}"


def apply_safe_deletes(findings: list[Finding], project: str) -> list[str]:
    actions: list[str] = []
    for f in findings:
        if not f.safe_to_delete:
            continue
        if f.category == "ZOMBIE_DISK":
            res = subprocess.run(
                ["gcloud", "compute", "disks", "delete", f.disk_name,
                 "--zone", f.disk_zone, "--project", project, "--quiet"],
                capture_output=True, text=True,
            )
            actions.append(_action_line(res.returncode == 0,
                                        f"gcloud disk delete {f.disk_name} ({f.disk_size_gb}GB)", res))
        elif f.category == "RELEASED_PV":
            if f.pv_name and f.pv_name != "-":
                res = subprocess.run(
                    ["kubectl", "delete", "pv", f.pv_name, "--wait=false"],
                    capture_output=True, text=True,
                )
                ok = res.returncode == 0
                actions.append(_action_line(ok, f"kubectl delete pv {f.pv_name}", res))
                if ok and f.disk_name == "(no disk)":
                    # With the disk already gone, a stale external-attacher
                    # finalizer holds the PV in Terminating forever; clearing
                    # it is safe because there is nothing left to detach.
                    still = subprocess.run(["kubectl", "get", "pv", f.pv_name],
                                           capture_output=True, text=True)
                    if still.returncode == 0:
                        res = subprocess.run(
                            ["kubectl", "patch", "pv", f.pv_name, "--type", "merge",
                             "-p", '{"metadata":{"finalizers":null}}'],
                            capture_output=True, text=True,
                        )
                        actions.append(_action_line(res.returncode == 0,
                                                    f"kubectl clear finalizers pv {f.pv_name}", res))
            if f.disk_name and f.disk_name != "(no disk)":
                res = subprocess.run(
                    ["gcloud", "compute", "disks", "delete", f.disk_name,
                     "--zone", f.disk_zone, "--project", project, "--quiet"],
                    capture_output=True, text=True,
                )
                actions.append(_action_line(res.returncode == 0,
                                            f"gcloud disk delete {f.disk_name} ({f.disk_size_gb}GB)", res))
    return actions


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project", required=True, help="GCP project ID")
    p.add_argument("--age-days", type=int, default=14,
                   help="Minimum days since last detach before auto-deleting (default 14)")
    p.add_argument("--apply", action="store_true",
                   help="Actually delete safe categories (default: report only)")
    p.add_argument("--out", default="-", help="Markdown output file (- for stdout)")
    args = p.parse_args()

    inv = build_inventory(args.project)
    findings = classify(inv, args.age_days)

    # Diagnostic line on stderr (visible in CI logs but not in the report).
    sys.stderr.write(
        f"[audit] inventory: disks={len(inv.disks)} pvs={len(inv.pvs)} "
        f"pvcs={len(inv.pvcs)} cnpg_clusters={len(inv.cnpg)} "
        f"sts={len(inv.sts)} findings={len(findings)}\n"
    )

    actions: list[str] = []
    if args.apply:
        actions = apply_safe_deletes(findings, args.project)

    md = render_markdown(findings, args.age_days, applied=bool(actions))
    if actions:
        md += "\n## Action log\n\n"
        for a in actions:
            md += f"- {a}\n"

    if args.out == "-":
        sys.stdout.write(md)
    else:
        with open(args.out, "w") as f:
            f.write(md)

    # Exit non-zero if there are categories worth attention (so the workflow
    # can route them into an Issue).
    attention = any(
        f.category in ("ZOMBIE_DISK", "RELEASED_PV", "PVC_NO_OWNER",
                       "CNPG_OUT_OF_SCOPE", "STS_OUT_OF_SCOPE")
        for f in findings
    )
    return 1 if attention else 0


if __name__ == "__main__":
    sys.exit(main())
