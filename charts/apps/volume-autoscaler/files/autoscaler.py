#!/usr/bin/env python3
"""
volume-autoscaler — grows PVCs before they fill.

Stdlib only, on purpose: this runs from a plain `python:alpine` image with no
kubectl and no git binary, so there is nothing to keep patched beyond the base
image itself.

Two write paths, because the two resource shapes have different constraints:

  CNPG clusters   The new size is committed to this repo's values.yaml via the
                  GitHub Contents API. A live `kubectl patch` would be reverted
                  by ArgoCD self-heal (enabled on every *-postgres app) and,
                  because PVCs cannot shrink, that revert wedges the app
                  permanently OutOfSync. Git is the only durable path.

  Generic PVCs    The PVC object is patched directly. StatefulSet
                  volumeClaimTemplates are immutable, so no chart edit can grow
                  an existing volume — only the PVC itself can.

Every mutation is gated on dry-run, a per-volume absolute ceiling, and a
cooldown recorded as an annotation on the PVC.
"""

import base64
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from fnmatch import fnmatch

K8S_HOST = "https://kubernetes.default.svc"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
COOLDOWN_ANNOTATION = "volume-autoscaler.tesserix.com/last-resize"
GIB = 1024 ** 3

# --------------------------------------------------------------------------
# Config (injected as env by the CronJob)
# --------------------------------------------------------------------------
DRY_RUN = os.environ.get("DRY_RUN", "true").lower() == "true"
PROM_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus-server.monitoring.svc.cluster.local")
USAGE_PCT = float(os.environ.get("USAGE_PERCENT", "75"))
GROWTH = float(os.environ.get("GROWTH_FACTOR", "1.5"))
MIN_INC = int(os.environ.get("MIN_INCREMENT_GI", "5"))
MAX_INC = int(os.environ.get("MAX_INCREMENT_GI", "200"))
COOLDOWN_MIN = int(os.environ.get("COOLDOWN_MINUTES", "60"))
MAX_SIZES = json.loads(os.environ.get("MAX_SIZE_GI", '{"default":500}'))

CNPG_ENABLED = os.environ.get("CNPG_ENABLED", "true").lower() == "true"
CNPG_CHART_TMPL = os.environ.get("CNPG_CHART_TEMPLATE", "charts/apps/{cluster}/values.yaml")
CNPG_OVERRIDES = json.loads(os.environ.get("CNPG_CHART_OVERRIDES", "{}"))
CNPG_EXCLUDE_NS = json.loads(os.environ.get("CNPG_EXCLUDE_NAMESPACES", "[]"))

GENERIC_ENABLED = os.environ.get("GENERIC_ENABLED", "true").lower() == "true"
GENERIC_NS = json.loads(os.environ.get("GENERIC_NAMESPACES", "[]"))
GENERIC_EXCLUDE = json.loads(os.environ.get("GENERIC_EXCLUDE_PATTERNS", "[]"))

GIT_OWNER = os.environ.get("GIT_OWNER", "")
GIT_REPO = os.environ.get("GIT_REPO", "")
GIT_BRANCH = os.environ.get("GIT_BRANCH", "main")
GIT_AUTHOR = os.environ.get("GIT_AUTHOR_NAME", "volume-autoscaler")
GIT_EMAIL = os.environ.get("GIT_AUTHOR_EMAIL", "platform@tesserix.com")
GIT_TOKEN = os.environ.get("GIT_TOKEN", "")

_exit_code = 0


def log(level, msg, **kw):
    """One JSON object per line so Cloud Logging indexes the fields."""
    rec = {"ts": datetime.now(timezone.utc).isoformat(), "level": level, "msg": msg}
    rec.update(kw)
    print(json.dumps(rec), flush=True)


def fail(msg, **kw):
    global _exit_code
    _exit_code = 1
    log("ERROR", msg, **kw)


# --------------------------------------------------------------------------
# Kubernetes API
# --------------------------------------------------------------------------
def _sa_token():
    with open(f"{SA_DIR}/token") as fh:
        return fh.read().strip()


_ssl_ctx = None


def _k8s_ssl():
    """
    Built on first use rather than at import. Constructing it at module scope
    made the whole module unimportable anywhere the service-account CA is
    absent — which is every environment except a running pod, including the
    unit tests.
    """
    global _ssl_ctx
    if _ssl_ctx is None:
        _ssl_ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    return _ssl_ctx


def k8s(path, method="GET", body=None, content_type="application/strategic-merge-patch+json"):
    url = f"{K8S_HOST}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {_sa_token()}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, context=_k8s_ssl(), timeout=30) as resp:
        return json.loads(resp.read() or "{}")


def parse_quantity(q):
    """Kubernetes quantity -> bytes. Handles Ki/Mi/Gi/Ti and K/M/G/T."""
    q = str(q).strip()
    units = {
        "Ki": 1024, "Mi": 1024 ** 2, "Gi": 1024 ** 3, "Ti": 1024 ** 4,
        "K": 1000, "M": 1000 ** 2, "G": 1000 ** 3, "T": 1000 ** 4,
    }
    for suffix in ("Ki", "Mi", "Gi", "Ti", "K", "M", "G", "T"):
        if q.endswith(suffix):
            return int(float(q[: -len(suffix)]) * units[suffix])
    return int(float(q))


# --------------------------------------------------------------------------
# Usage collection
# --------------------------------------------------------------------------
def promql(query):
    """Run an instant PromQL query and return its result vector."""
    url = f"{PROM_URL.rstrip('/')}/api/v1/query?query={urllib.parse.quote(query)}"
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read() or "{}")
    if body.get("status") != "success":
        raise RuntimeError(f"promql failed: {body.get('error', 'unknown')}")
    return body.get("data", {}).get("result", [])


def collect_usage():
    """
    Map (namespace, pvc) -> (used_bytes, capacity_bytes) from Prometheus.

    Deliberately NOT read from the kubelet via /api/v1/nodes/<n>/proxy/...:
    the `nodes/proxy` RBAC verb that requires is not scoped to /stats/summary,
    it grants the whole kubelet API — including /exec and /run — which is a
    privilege-escalation path (flagged as HIGH by Trivy, KSV045). Prometheus
    already scrapes kubelet_volume_stats_*, so reading it there needs no
    Kubernetes node permissions at all.

    Only MOUNTED volumes report these metrics; an unmounted PVC simply does not
    appear and is skipped rather than guessed at.
    """
    usage = {}
    try:
        used = promql("kubelet_volume_stats_used_bytes")
        capacity = promql("kubelet_volume_stats_capacity_bytes")
    except Exception as exc:
        fail("cannot query Prometheus for volume stats",
             url=PROM_URL, error=str(exc))
        return usage

    def index(vec):
        out = {}
        for s in vec:
            m = s.get("metric", {})
            ns, pvc = m.get("namespace"), m.get("persistentvolumeclaim")
            if not ns or not pvc:
                continue
            try:
                out[(ns, pvc)] = float(s["value"][1])
            except (KeyError, IndexError, ValueError):
                continue
        return out

    used_by, cap_by = index(used), index(capacity)
    for key, cap in cap_by.items():
        if cap <= 0 or key not in used_by:
            continue
        usage[key] = (used_by[key], cap)
    return usage


# --------------------------------------------------------------------------
# Sizing decision
# --------------------------------------------------------------------------
def max_size_for(pvc_name):
    for prefix, cap in MAX_SIZES.items():
        if prefix != "default" and pvc_name.startswith(prefix):
            return int(cap)
    return int(MAX_SIZES.get("default", 500))


def decide(pvc_name, used, capacity):
    """
    Return the new size in GiB, or None to leave the volume alone.

    Growth is computed from the CURRENT CAPACITY, never from usage, so a volume
    grows in predictable steps regardless of how fast it filled.
    """
    pct = used / capacity * 100.0
    if pct < USAGE_PCT:
        return None

    cur_gi = capacity / GIB
    target = cur_gi * GROWTH
    increment = target - cur_gi
    if increment < MIN_INC:
        target = cur_gi + MIN_INC
    if increment > MAX_INC:
        target = cur_gi + MAX_INC

    new_gi = int(target + 0.999)  # ceil
    ceiling = max_size_for(pvc_name)

    if cur_gi >= ceiling:
        fail(
            "volume at ceiling and still over threshold — MANUAL ACTION REQUIRED",
            pvc=pvc_name, usage_pct=round(pct, 1), size_gi=int(cur_gi), ceiling_gi=ceiling,
        )
        return None

    if new_gi > ceiling:
        log("WARN", "capping growth at ceiling", pvc=pvc_name, wanted_gi=new_gi, ceiling_gi=ceiling)
        new_gi = ceiling

    # Never shrink. Guards against a stale/incorrect capacity reading.
    if new_gi <= int(cur_gi):
        return None
    return new_gi


def in_cooldown(pvc_obj):
    ann = (pvc_obj.get("metadata", {}).get("annotations") or {}).get(COOLDOWN_ANNOTATION)
    if not ann:
        return False
    try:
        last = datetime.fromisoformat(ann.replace("Z", "+00:00"))
    except ValueError:
        return False
    return datetime.now(timezone.utc) - last < timedelta(minutes=COOLDOWN_MIN)


def stamp_cooldown(ns, name):
    if DRY_RUN:
        return
    patch = {"metadata": {"annotations": {COOLDOWN_ANNOTATION: datetime.now(timezone.utc).isoformat()}}}
    try:
        k8s(f"/api/v1/namespaces/{ns}/persistentvolumeclaims/{name}", "PATCH", patch)
    except Exception as exc:
        log("WARN", "could not stamp cooldown annotation", pvc=name, error=str(exc))


# --------------------------------------------------------------------------
# GitHub write-back (CNPG)
# --------------------------------------------------------------------------
def gh(path, method="GET", body=None):
    url = f"https://api.github.com{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {GIT_TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or "{}")


def rewrite_size_key(text, key, new_gi):
    """
    Replace a top-level `key: <n>Gi` line, preserving any trailing comment.
    Returns (new_text, old_value) or (None, None) when the key is absent.
    """
    out, old = [], None
    for line in text.split("\n"):
        stripped = line.strip()
        if old is None and stripped.startswith(f"{key}:") and not stripped.startswith("#"):
            value = stripped[len(key) + 1:].strip()
            comment = ""
            if "#" in value:
                value, comment = value.split("#", 1)
                comment = "  #" + comment
            old = value.strip().strip('"').strip("'")
            out.append(f"{key}: {new_gi}Gi{comment}")
        else:
            out.append(line)
    if old is None:
        return None, None
    return "\n".join(out), old


def commit_cnpg_size(cluster, chart_path, key, new_gi, pvc):
    """
    Update `key` in the cluster's values.yaml. The file is re-read immediately
    before the write and the commit is conditioned on the blob SHA, so a
    concurrent change fails the commit rather than silently clobbering it.
    """
    try:
        meta = gh(f"/repos/{GIT_OWNER}/{GIT_REPO}/contents/{chart_path}?ref={GIT_BRANCH}")
    except urllib.error.HTTPError as exc:
        fail("chart values.yaml not found — skipping write-back",
             cluster=cluster, path=chart_path, status=exc.code)
        return False

    text = base64.b64decode(meta["content"]).decode()

    # Verify this file really belongs to this cluster before rewriting it.
    # Convention resolved the path; this proves it.
    if f"clusterName: {cluster}" not in text:
        fail("values.yaml does not declare this clusterName — refusing to write",
             cluster=cluster, path=chart_path)
        return False

    new_text, old = rewrite_size_key(text, key, new_gi)
    if new_text is None:
        fail("size key absent from values.yaml", cluster=cluster, path=chart_path, key=key)
        return False
    if new_text == text:
        return False

    if DRY_RUN:
        log("DRY_RUN", "would commit size change", cluster=cluster, path=chart_path,
            key=key, old=old, new=f"{new_gi}Gi", pvc=pvc)
        return True

    body = {
        "message": (
            f"chore({cluster}): grow {key} {old} -> {new_gi}Gi\n\n"
            f"Automated by volume-autoscaler: {pvc} crossed {USAGE_PCT}% utilisation."
        ),
        "content": base64.b64encode(new_text.encode()).decode(),
        "sha": meta["sha"],
        "branch": GIT_BRANCH,
        "committer": {"name": GIT_AUTHOR, "email": GIT_EMAIL},
    }
    try:
        gh(f"/repos/{GIT_OWNER}/{GIT_REPO}/contents/{chart_path}", "PUT", body)
    except urllib.error.HTTPError as exc:
        # 409 = the blob moved under us; next cycle re-reads and retries.
        fail("commit failed", cluster=cluster, path=chart_path, status=exc.code,
             detail=exc.read().decode()[:300])
        return False

    log("INFO", "committed size change — ArgoCD will sync",
        cluster=cluster, path=chart_path, key=key, old=old, new=f"{new_gi}Gi", pvc=pvc)
    return True


# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
def handle_cnpg(usage):
    try:
        clusters = k8s("/apis/postgresql.cnpg.io/v1/clusters")["items"]
    except Exception as exc:
        fail("cannot list CNPG clusters", error=str(exc))
        return

    for cl in clusters:
        name = cl["metadata"]["name"]
        ns = cl["metadata"]["namespace"]
        if ns in CNPG_EXCLUDE_NS:
            continue

        if name in CNPG_OVERRIDES:
            chart_path = CNPG_OVERRIDES[name]
            if not chart_path:
                log("INFO", "cluster excluded from write-back (alert-only)", cluster=name)
                chart_path = None
        else:
            chart_path = CNPG_CHART_TMPL.format(cluster=name)

        # A CNPG cluster's PVCs are <cluster>-<n> for data and <cluster>-<n>-wal
        # for WAL. Each maps to a different values.yaml key.
        for (pvc_ns, pvc), (used, cap) in sorted(usage.items()):
            if pvc_ns != ns or not pvc.startswith(name):
                continue
            is_wal = pvc.endswith("-wal")
            key = "walStorageSize" if is_wal else "storageSize"

            new_gi = decide(pvc, used, cap)
            if new_gi is None:
                continue

            log("INFO", "growth needed", kind="cnpg", cluster=name, pvc=pvc,
                usage_pct=round(used / cap * 100, 1),
                current_gi=int(cap / GIB), target_gi=new_gi)

            if not chart_path:
                continue
            try:
                pvc_obj = k8s(f"/api/v1/namespaces/{ns}/persistentvolumeclaims/{pvc}")
                if in_cooldown(pvc_obj):
                    log("INFO", "in cooldown, skipping", pvc=pvc)
                    continue
            except Exception:
                pass

            if commit_cnpg_size(name, chart_path, key, new_gi, pvc):
                stamp_cooldown(ns, pvc)


def handle_generic(usage):
    for (ns, pvc), (used, cap) in sorted(usage.items()):
        if ns not in GENERIC_NS:
            continue
        if any(fnmatch(pvc, pat) for pat in GENERIC_EXCLUDE):
            continue

        try:
            pvc_obj = k8s(f"/api/v1/namespaces/{ns}/persistentvolumeclaims/{pvc}")
        except Exception as exc:
            log("WARN", "cannot read pvc", ns=ns, pvc=pvc, error=str(exc))
            continue

        # A PVC owned by a CNPG cluster is handled by the git path; never patch
        # it in place, or ArgoCD and the autoscaler will fight over it.
        labels = pvc_obj.get("metadata", {}).get("labels") or {}
        if "cnpg.io/cluster" in labels:
            continue

        new_gi = decide(pvc, used, cap)
        if new_gi is None:
            continue
        if in_cooldown(pvc_obj):
            log("INFO", "in cooldown, skipping", pvc=pvc)
            continue

        # Requested size can legitimately exceed capacity mid-resize; don't
        # stack a second patch on top of one already in flight.
        requested = pvc_obj["spec"]["resources"]["requests"]["storage"]
        if parse_quantity(requested) >= new_gi * GIB:
            continue

        log("INFO", "growth needed", kind="generic", ns=ns, pvc=pvc,
            usage_pct=round(used / cap * 100, 1),
            current_gi=int(cap / GIB), target_gi=new_gi)

        if DRY_RUN:
            log("DRY_RUN", "would patch pvc", ns=ns, pvc=pvc,
                old=requested, new=f"{new_gi}Gi")
            continue

        patch = {"spec": {"resources": {"requests": {"storage": f"{new_gi}Gi"}}}}
        try:
            k8s(f"/api/v1/namespaces/{ns}/persistentvolumeclaims/{pvc}", "PATCH", patch)
        except urllib.error.HTTPError as exc:
            fail("pvc patch failed", ns=ns, pvc=pvc, status=exc.code,
                 detail=exc.read().decode()[:300])
            continue

        log("INFO", "patched pvc", ns=ns, pvc=pvc, old=requested, new=f"{new_gi}Gi")
        stamp_cooldown(ns, pvc)


def main():
    log("INFO", "volume-autoscaler starting", dry_run=DRY_RUN,
        usage_threshold_pct=USAGE_PCT, growth_factor=GROWTH)

    if not DRY_RUN and CNPG_ENABLED and not GIT_TOKEN:
        fail("CNPG write-back enabled but GIT_TOKEN is empty — cannot commit")
        return 1

    usage = collect_usage()
    log("INFO", "collected volume usage", volumes=len(usage))
    if not usage:
        fail("no volume usage collected — check kubelet stats RBAC")
        return _exit_code

    if CNPG_ENABLED:
        handle_cnpg(usage)
    if GENERIC_ENABLED:
        handle_generic(usage)

    log("INFO", "volume-autoscaler finished", exit_code=_exit_code)
    return _exit_code


if __name__ == "__main__":
    sys.exit(main())
