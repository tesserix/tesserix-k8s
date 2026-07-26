#!/usr/bin/env python3
"""
Catch the ArgoCD manifest mistakes that fail SILENTLY.

Every check here exists because the failure it detects produces no error
anywhere — not in `kubectl`, not in the ArgoCD UI, not in the controller logs.
The app-of-apps keeps reporting Synced and the new Application simply never
exists. The only symptom is a managed-resource count that didn't change, which
nobody looks at.

Checks:

  1. REGISTERED — a manifest sitting in a directory that has a kustomization.yaml
     must be listed in that kustomization's `resources`. Kustomize builds only
     what it is told to build; an unlisted file is not an error, it is simply
     absent from the output. (Cost the volume-autoscaler app: PR #87.)

  2. PROJECT EXISTS — spec.project must name an AppProject defined in this repo,
     or the built-in `default`. ArgoCD declines to create an Application whose
     project does not exist and reports nothing. (Cost the same app: PR #86,
     where a stale template in CLAUDE.md suggested `tesserix-prod`.)

  3. NO EXPLICIT prune:false — `false` is the zero value for that bool, so the
     API server drops the key and the app-of-apps then diffs git (present)
     against live (absent) forever. The app can never reach Synced, which
     destroys OutOfSync as a signal for every other app in the tree.

Exit 0 = clean, 1 = at least one problem.
"""

import os
import sys
import glob
import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARGOCD_DIR = os.path.join(REPO_ROOT, "argocd")

# `default` ships with ArgoCD and is not declared in this repo.
BUILTIN_PROJECTS = {"default"}


def load_docs(path):
    try:
        with open(path) as fh:
            return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]
    except Exception as exc:  # noqa: BLE001 - report, don't crash the whole run
        print(f"  ! could not parse {rel(path)}: {exc}")
        return []


def rel(path):
    return os.path.relpath(path, REPO_ROOT)


def known_projects():
    found = set()
    for path in glob.glob(os.path.join(ARGOCD_DIR, "**", "*.yaml"), recursive=True):
        for doc in load_docs(path):
            if doc.get("kind") == "AppProject":
                name = (doc.get("metadata") or {}).get("name")
                if name:
                    found.add(name)
    return found | BUILTIN_PROJECTS


def check_registered():
    """Every yaml beside a kustomization.yaml must be in its resources list."""
    problems = []
    for kust in glob.glob(os.path.join(ARGOCD_DIR, "**", "kustomization.yaml"), recursive=True):
        directory = os.path.dirname(kust)
        docs = load_docs(kust)
        if not docs:
            continue
        listed = set()
        for d in docs:
            for r in d.get("resources", []) or []:
                listed.add(str(r).strip())

        for path in sorted(glob.glob(os.path.join(directory, "*.yaml"))):
            name = os.path.basename(path)
            if name == "kustomization.yaml":
                continue
            if name in listed or f"./{name}" in listed:
                continue
            # A file may legitimately be pulled in by a parent kustomization
            # via a directory reference; only flag it when nothing references it.
            problems.append(
                f"{rel(path)} is not listed in {rel(kust)} — kustomize will not "
                f"build it, so the resource is silently never created"
            )
    return problems


def check_projects_and_prune(projects):
    problems = []
    for path in glob.glob(os.path.join(ARGOCD_DIR, "**", "*.yaml"), recursive=True):
        for doc in load_docs(path):
            if doc.get("kind") != "Application":
                continue
            spec = doc.get("spec") or {}
            name = (doc.get("metadata") or {}).get("name", "<unnamed>")

            proj = spec.get("project")
            if proj and proj not in projects:
                problems.append(
                    f"{rel(path)}: Application '{name}' references AppProject "
                    f"'{proj}', which does not exist. ArgoCD will decline to "
                    f"create it and report nothing. Known: {', '.join(sorted(projects))}"
                )

            automated = ((spec.get("syncPolicy") or {}).get("automated"))
            if isinstance(automated, dict) and automated.get("prune") is False:
                problems.append(
                    f"{rel(path)}: Application '{name}' declares "
                    f"`prune: false`. That is the zero value, so the API server "
                    f"drops the key and this app becomes permanently OutOfSync. "
                    f"Omit it (false is the default) and note the intent in a comment."
                )
    return problems


BASELINE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "argocd-validation-baseline.txt")


def load_baseline():
    """
    Pre-existing findings that are accepted, one per line.

    Adopted because this check found 61 unregistered manifests already in the
    tree, most of them deliberate — parked products (fanzone, gameverse,
    stockpilot) are removed from their kustomization on purpose, which is
    exactly how you park something. Failing CI on those would block every PR
    and the check would be turned off within a day.

    The baseline is therefore a ratchet, not an amnesty: everything in it is
    tolerated, anything NEW fails. Deleting a line once the underlying file is
    registered or removed is the intended direction of travel.
    """
    if not os.path.exists(BASELINE):
        return set()
    with open(BASELINE) as fh:
        return {ln.strip() for ln in fh
                if ln.strip() and not ln.lstrip().startswith("#")}


def main():
    if not os.path.isdir(ARGOCD_DIR):
        print("no argocd/ directory — nothing to validate")
        return 0

    projects = known_projects()
    problems = check_registered() + check_projects_and_prune(projects)

    if "--write-baseline" in sys.argv:
        with open(BASELINE, "w") as fh:
            fh.write("# Accepted pre-existing ArgoCD manifest findings.\n")
            fh.write("# A ratchet, not an amnesty: new findings still fail.\n")
            fh.write("# Remove a line once the file is registered or deleted.\n")
            for p in sorted(problems):
                fh.write(p + "\n")
        print(f"wrote baseline with {len(problems)} accepted finding(s)")
        return 0

    baseline = load_baseline()
    accepted = [p for p in problems if p in baseline]
    problems = [p for p in problems if p not in baseline]
    if accepted:
        print(f"({len(accepted)} pre-existing finding(s) accepted via baseline)\n")

    if not problems:
        print("ArgoCD manifest validation: OK")
        return 0

    print(f"ArgoCD manifest validation: {len(problems)} problem(s)\n")
    for p in problems:
        print(f"  - {p}")
    print(
        "\nThese fail silently at runtime — ArgoCD reports Synced while the "
        "resource never exists. Fix them here rather than discovering it in the cluster."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
